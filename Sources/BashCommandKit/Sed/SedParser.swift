import Foundation

/// Single-pass scanner-style parser that walks the script source
/// directly. Sed's grammar is context-sensitive so a separate
/// tokenizer would just defer the work; we read commands top-down,
/// each command type knowing how to consume the rest of its own
/// syntax. The parser produces a flat command list — groups (`{...}`)
/// and labels share the surrounding scope, exactly like real sed.
public enum SedParser {

    /// Parse one or more `-e` script fragments into a unified command
    /// list. Fragments are joined with newlines (so `{` in one and `}`
    /// in another work). A `#n`/`#r` shebang-style comment in the very
    /// first fragment toggles silent / extended modes.
    public static func parse(scripts: [String], extendedRegex: Bool = false)
        throws -> (commands: [SedCommandNode], silentMode: Bool, extendedMode: Bool)
    {
        // Combine -e fragments. If a fragment ends with a single
        // backslash, keep it as continuation (lexer handles a/i/c).
        var combined = scripts.joined(separator: "\n")

        var silent = false
        var ereFromComment = false
        // Strip leading `#n` / `#r` / `#nr` shebang comment.
        if let firstLineEnd = combined.firstIndex(of: "\n") {
            let firstLine = combined[combined.startIndex..<firstLineEnd]
            if firstLine.hasPrefix("#") {
                let body = firstLine.dropFirst()
                let lower = body.lowercased()
                if lower.allSatisfy({ $0 == "n" || $0 == "r" }) && !body.isEmpty {
                    if lower.contains("n") { silent = true }
                    if lower.contains("r") { ereFromComment = true }
                    combined = String(combined[combined.index(after: firstLineEnd)...])
                }
            }
        } else if combined.hasPrefix("#") {
            let body = combined.dropFirst()
            let lower = body.lowercased()
            if !body.isEmpty, lower.allSatisfy({ $0 == "n" || $0 == "r" }) {
                if lower.contains("n") { silent = true }
                if lower.contains("r") { ereFromComment = true }
                combined = ""
            }
        }

        var p = Parser(source: combined, extendedRegex: extendedRegex || ereFromComment)
        let commands = try p.parseScript()
        try validateLabels(commands)
        return (commands, silent, ereFromComment)
    }

    // MARK: - Validation

    static func validateLabels(_ commands: [SedCommandNode]) throws {
        var defined = Set<String>()
        collect(commands, into: &defined)
        if let bad = findUndefined(commands, defined: defined) {
            throw SedScriptError("undefined label '\(bad)'")
        }
    }

    private static func collect(_ commands: [SedCommandNode], into out: inout Set<String>) {
        for c in commands {
            switch c {
            case .label(let n): out.insert(n)
            case .group(_, let inner): collect(inner, into: &out)
            default: break
            }
        }
    }

    private static func findUndefined(_ commands: [SedCommandNode], defined: Set<String>) -> String? {
        for c in commands {
            switch c {
            case .branch(_, let l), .branchOnSubst(_, let l), .branchOnNoSubst(_, let l):
                if let label = l, !label.isEmpty, !defined.contains(label) { return label }
            case .group(_, let inner):
                if let bad = findUndefined(inner, defined: defined) { return bad }
            default: break
            }
        }
        return nil
    }

    // MARK: - Recursive-descent parser

    fileprivate struct Parser {
        let chars: [Character]
        var pos = 0
        let extendedRegex: Bool

        init(source: String, extendedRegex: Bool) {
            self.chars = Array(source)
            self.extendedRegex = extendedRegex
        }

        mutating func parseScript() throws -> [SedCommandNode] {
            var out: [SedCommandNode] = []
            while !atEnd {
                skipBlankSeparators()
                if atEnd { break }
                if peek() == "}" { break }   // top-level: stray `}` ends the loop
                if let cmd = try parseOne() {
                    out.append(cmd)
                }
            }
            return out
        }

        var atEnd: Bool { pos >= chars.count }
        func peek(_ offset: Int = 0) -> Character? {
            let i = pos + offset
            return i < chars.count ? chars[i] : nil
        }
        @discardableResult mutating func advance() -> Character {
            let c = chars[pos]; pos += 1; return c
        }
        mutating func skipBlankSeparators() {
            while !atEnd {
                let c = chars[pos]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == ";" {
                    pos += 1
                } else if c == "#" {
                    // Comment to end of line
                    while !atEnd && chars[pos] != "\n" { pos += 1 }
                } else {
                    break
                }
            }
        }
        mutating func skipHorizontalSpace() {
            while !atEnd, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
        }

        // Parse one command (with optional address[,address][!]).
        mutating func parseOne() throws -> SedCommandNode? {
            // Address parsing
            var range = SedAddressRange()
            if let start = try parseAddress() {
                range.start = start
                skipHorizontalSpace()
                if !atEnd && chars[pos] == "," {
                    pos += 1
                    skipHorizontalSpace()
                    if !atEnd, chars[pos] == "+" && (peek(1).map { $0.isASCII && $0.isNumber } == true) {
                        pos += 1
                        let n = readNumber()
                        range.end = .relative(offset: n)
                    } else {
                        guard let end = try parseAddress() else {
                            throw SedScriptError("expected context address")
                        }
                        range.end = end
                    }
                }
            } else if !atEnd, chars[pos] == "," {
                throw SedScriptError("expected context address")
            }
            skipHorizontalSpace()
            if !atEnd, chars[pos] == "!" {
                pos += 1
                range.negated = true
                skipHorizontalSpace()
            }
            if atEnd {
                if range.start != nil { throw SedScriptError("command expected") }
                return nil
            }
            return try parseCommandBody(range: range)
        }

        mutating func parseAddress() throws -> SedAddress? {
            guard !atEnd else { return nil }
            let c = chars[pos]
            if c.isASCII, c.isNumber {
                let n = readNumber()
                if !atEnd, chars[pos] == "~" {
                    pos += 1
                    let step = readNumber()
                    return .step(first: n, step: step)
                }
                return .line(n)
            }
            if c == "$" { pos += 1; return .last }
            if c == "/" || c == "\\" {
                // \cREGEXc — alternate delimiter
                let delim: Character
                if c == "\\" {
                    pos += 1
                    if atEnd { throw SedScriptError("expected pattern delimiter") }
                    delim = chars[pos]; pos += 1
                } else {
                    delim = "/"; pos += 1
                }
                let pat = try readDelimited(until: delim, allowBracket: true)
                return .regex(pat)
            }
            return nil
        }

        mutating func readNumber() -> Int {
            var n = 0
            while !atEnd, let v = chars[pos].asciiValue, v >= 0x30, v <= 0x39 {
                n = n * 10 + Int(v - 0x30); pos += 1
            }
            return n
        }

        /// Read until an unescaped `terminator` (consuming it). If
        /// `allowBracket`, `[..]` regions are passed through verbatim
        /// (the terminator inside brackets is literal).
        mutating func readDelimited(until terminator: Character, allowBracket: Bool) throws -> String {
            var out = ""
            var inBracket = false
            while !atEnd {
                let c = chars[pos]
                if c == terminator && !inBracket {
                    pos += 1
                    return out
                }
                if c == "\n" { break }
                if c == "\\", pos + 1 < chars.count {
                    let next = chars[pos + 1]
                    // Unescape the terminator (drop backslash); keep
                    // other escapes for the regex layer.
                    if next == terminator && !inBracket {
                        out.append(terminator); pos += 2; continue
                    }
                    out.append(c); out.append(next); pos += 2; continue
                }
                if allowBracket {
                    if c == "[" && !inBracket {
                        inBracket = true; out.append(c); pos += 1
                        if !atEnd, chars[pos] == "^" { out.append(chars[pos]); pos += 1 }
                        if !atEnd, chars[pos] == "]" { out.append(chars[pos]); pos += 1 }
                        continue
                    }
                    if c == "]" && inBracket {
                        inBracket = false; out.append(c); pos += 1; continue
                    }
                }
                out.append(c); pos += 1
            }
            throw SedScriptError("unterminated `\(terminator)`")
        }

        mutating func parseCommandBody(range: SedAddressRange) throws -> SedCommandNode? {
            guard !atEnd else { return nil }
            let c = chars[pos]
            switch c {
            case "{":
                pos += 1
                var inner: [SedCommandNode] = []
                while true {
                    skipBlankSeparators()
                    if atEnd { throw SedScriptError("unmatched brace in grouped commands") }
                    if chars[pos] == "}" { pos += 1; break }
                    if let cmd = try parseOne() {
                        inner.append(cmd)
                    }
                }
                return .group(range, inner)
            case "}":
                throw SedScriptError("unexpected '}'")
            case "s":
                pos += 1
                return try parseSubstitute(range: range)
            case "y":
                pos += 1
                return try parseTransliterate(range: range)
            case "a", "i":
                let cmd = c
                pos += 1
                let text = readTextLines()
                return cmd == "a" ? .append(range, text: text) : .insert(range, text: text)
            case "c":
                pos += 1
                let text = readTextLines()
                return .change(range, text: text)
            case "b":
                pos += 1
                let label = readLabel()
                return .branch(range, label: label)
            case "t":
                pos += 1
                let label = readLabel()
                return .branchOnSubst(range, label: label)
            case "T":
                pos += 1
                let label = readLabel()
                return .branchOnNoSubst(range, label: label)
            case ":":
                pos += 1
                skipHorizontalSpace()
                let name = readLabel() ?? ""
                if name.isEmpty { throw SedScriptError("missing label name") }
                return .label(name: name)
            case "r":
                pos += 1
                return .readFile(range, filename: readFilename())
            case "R":
                pos += 1
                return .readFileLine(range, filename: readFilename())
            case "w":
                pos += 1
                return .writeFile(range, filename: readFilename())
            case "W":
                pos += 1
                return .writeFirstLine(range, filename: readFilename())
            case "e":
                pos += 1
                skipHorizontalSpace()
                let cmd = readUntilLineEnd()
                return .execute(range, command: cmd.isEmpty ? nil : cmd)
            case "v":
                pos += 1
                skipHorizontalSpace()
                let v = readUntilLineEnd()
                return .version(range, minVersion: v.isEmpty ? nil : v)
            case "p":
                pos += 1; return .print(range)
            case "P":
                pos += 1; return .printFirstLine(range)
            case "d":
                pos += 1; return .delete(range)
            case "D":
                pos += 1; return .deleteFirstLine(range)
            case "h":
                pos += 1; return .hold(range)
            case "H":
                pos += 1; return .holdAppend(range)
            case "g":
                pos += 1; return .get(range)
            case "G":
                pos += 1; return .getAppend(range)
            case "x":
                pos += 1; return .exchange(range)
            case "n":
                pos += 1; return .next(range)
            case "N":
                pos += 1; return .nextAppend(range)
            case "q":
                pos += 1; return .quit(range)
            case "Q":
                pos += 1; return .quitSilent(range)
            case "z":
                pos += 1; return .zap(range)
            case "=":
                pos += 1; return .lineNumber(range)
            case "l":
                pos += 1; return .list(range)
            case "F":
                pos += 1; return .printFilename(range)
            default:
                throw SedScriptError("unknown command: '\(c)'")
            }
        }

        mutating func parseSubstitute(range: SedAddressRange) throws -> SedCommandNode {
            guard !atEnd else { throw SedScriptError("expected delimiter after 's'") }
            let delim = chars[pos]
            if delim == "\n" { throw SedScriptError("unterminated s command") }
            pos += 1
            let pattern = try readDelimited(until: delim, allowBracket: true)
            let replacement = try readSubstituteReplacement(until: delim)
            // Read flags
            var global = false
            var ignoreCase = false
            var printOnMatch = false
            var nth: Int? = nil
            var writeFile: String? = nil
            while !atEnd {
                let f = chars[pos]
                if f == ";" || f == "\n" || f == "}" { break }
                if f == " " || f == "\t" { pos += 1; continue }
                if f == "g" { global = true; pos += 1; continue }
                if f == "i" || f == "I" { ignoreCase = true; pos += 1; continue }
                if f == "p" { printOnMatch = true; pos += 1; continue }
                if f.isASCII, f.isNumber {
                    nth = readNumber(); continue
                }
                if f == "w" {
                    pos += 1
                    skipHorizontalSpace()
                    writeFile = readUntilLineEnd()
                    break
                }
                if f == "e" {
                    // Sandbox: silently ignore
                    pos += 1; continue
                }
                if f == "M" || f == "m" {
                    // multiline mode — accept but no-op for now
                    pos += 1; continue
                }
                throw SedScriptError("unknown s flag: \(f)")
            }
            return .substitute(addr: range, pattern: pattern, replacement: replacement,
                               global: global, ignoreCase: ignoreCase, printOnMatch: printOnMatch,
                               nthOccurrence: nth, extendedRegex: extendedRegex,
                               writeFile: writeFile)
        }

        /// Substitute replacement: parse the part between the two
        /// remaining delimiters. Distinct from address regex parsing
        /// because sed allows `\\<newline>` and `\<newline>` for
        /// multi-line replacements.
        mutating func readSubstituteReplacement(until terminator: Character) throws -> String {
            var out = ""
            while !atEnd {
                let c = chars[pos]
                if c == terminator { pos += 1; return out }
                if c == "\n" {
                    throw SedScriptError("unterminated `s' command")
                }
                if c == "\\" && pos + 1 < chars.count {
                    pos += 1
                    let next = chars[pos]
                    if next == "\\" {
                        pos += 1
                        if !atEnd && chars[pos] == "\n" {
                            // \\<newline> → literal newline
                            out += "\n"; pos += 1
                        } else {
                            out += "\\"
                        }
                    } else if next == "\n" {
                        out += "\n"; pos += 1
                    } else if next == terminator {
                        // escaped terminator → literal
                        out.append(terminator); pos += 1
                    } else {
                        out += "\\"; out.append(next); pos += 1
                    }
                    continue
                }
                out.append(c); pos += 1
            }
            throw SedScriptError("unterminated `s' command")
        }

        mutating func parseTransliterate(range: SedAddressRange) throws -> SedCommandNode {
            guard !atEnd else { throw SedScriptError("expected delimiter after 'y'") }
            let delim = chars[pos]; pos += 1
            let source = try readTransliterateOperand(until: delim)
            let dest = try readTransliterateOperand(until: delim)
            if source.count != dest.count {
                throw SedScriptError("transliteration sets must have same length")
            }
            // Allow only separators after y
            skipHorizontalSpace()
            if !atEnd {
                let n = chars[pos]
                if n != ";" && n != "\n" && n != "}" {
                    throw SedScriptError("extra text at the end of a transform command")
                }
            }
            return .transliterate(range, source: source, dest: dest)
        }

        mutating func readTransliterateOperand(until terminator: Character) throws -> String {
            var out = ""
            while !atEnd {
                let c = chars[pos]
                if c == terminator { pos += 1; return out }
                if c == "\n" { throw SedScriptError("unterminated y command") }
                if c == "\\" && pos + 1 < chars.count {
                    pos += 1
                    let n = chars[pos]
                    switch n {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "r": out += "\r"
                    case "\\": out += "\\"
                    default:
                        if n == terminator { out.append(terminator) }
                        else { out.append(n) }
                    }
                    pos += 1
                } else {
                    out.append(c); pos += 1
                }
            }
            throw SedScriptError("unterminated y command")
        }

        /// Read a/i/c text. Supports `a\` followed by newline + text
        /// (line continuation via trailing `\`), the GNU "a text" one-
        /// liner, and `\n` / `\t` / `\r` escapes inside the text.
        mutating func readTextLines() -> String {
            // Optional `\` after the command (only consume if followed by
            // newline / space).
            if !atEnd, chars[pos] == "\\",
               pos + 1 < chars.count,
               chars[pos + 1] == "\n" || chars[pos + 1] == " " || chars[pos + 1] == "\t" {
                pos += 1
            }
            // Optional space.
            if !atEnd, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
            // GNU `\` to preserve leading whitespace.
            if !atEnd, chars[pos] == "\\", pos + 1 < chars.count,
               chars[pos + 1] == " " || chars[pos + 1] == "\t" {
                pos += 1
            }
            // If a `\<newline>` was the only thing, we are now positioned
            // at the newline — consume it.
            if !atEnd, chars[pos] == "\n" { pos += 1 }

            var text = ""
            while !atEnd {
                let c = chars[pos]
                if c == "\n" {
                    if text.hasSuffix("\\") {
                        text.removeLast()
                        text += "\n"
                        pos += 1
                        continue
                    }
                    break
                }
                if c == "\\" && pos + 1 < chars.count {
                    let next = chars[pos + 1]
                    switch next {
                    case "n": text += "\n"; pos += 2; continue
                    case "t": text += "\t"; pos += 2; continue
                    case "r": text += "\r"; pos += 2; continue
                    default: break
                    }
                }
                text.append(c); pos += 1
            }
            return text
        }

        mutating func readLabel() -> String? {
            skipHorizontalSpace()
            var s = ""
            while !atEnd {
                let c = chars[pos]
                if c == " " || c == "\t" || c == "\n" || c == ";" || c == "}" || c == "{" { break }
                s.append(c); pos += 1
            }
            return s.isEmpty ? nil : s
        }

        mutating func readFilename() -> String {
            skipHorizontalSpace()
            return readUntilLineEnd().trimmingCharacters(in: .whitespaces)
        }

        mutating func readUntilLineEnd() -> String {
            var s = ""
            while !atEnd, chars[pos] != "\n", chars[pos] != ";" {
                s.append(chars[pos]); pos += 1
            }
            return s
        }
    }
}
