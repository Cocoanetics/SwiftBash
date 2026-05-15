// swiftlint:disable file_length
import Foundation

// Single-pass scanner-style parser that walks the script source
// directly. Sed's grammar is context-sensitive so a separate
// tokenizer would just defer the work; we read commands top-down,
// each command type knowing how to consume the rest of its own
// syntax. The parser produces a flat command list — groups (`{...}`)
// and labels share the surrounding scope, exactly like real sed.
// swiftlint:disable:next type_body_length
public enum SedParser {

    /// Result of parsing one or more `-e` script fragments.
    public struct ParseResult {
        public let commands: [SedCommandNode]
        public let silentMode: Bool
        public let extendedMode: Bool
    }

    /// Parse one or more `-e` script fragments into a unified command
    /// list. Fragments are joined with newlines (so `{` in one and `}`
    /// in another work). A `#n`/`#r` shebang-style comment in the very
    /// first fragment toggles silent / extended modes.
    public static func parse(scripts: [String], extendedRegex: Bool = false)
        throws -> ParseResult {
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

        var parser = Parser(source: combined, extendedRegex: extendedRegex || ereFromComment)
        let commands = try parser.parseScript()
        try validateLabels(commands)
        return ParseResult(
            commands: commands, silentMode: silent, extendedMode: ereFromComment)
    }

    // MARK: - Validation

    static func validateLabels(_ commands: [SedCommandNode]) throws {
        var defined = Set<String>()
        collect(commands, into: &defined)
        if let bad = findUndefined(commands, defined: defined) {
            throw SedScriptError("undefined label '\(bad)'")
        }
    }

    private static func collect(_ commands: [SedCommandNode],
                                into out: inout Set<String>) {
        for command in commands {
            switch command {
            case .label(let name): out.insert(name)
            case .group(_, let inner): collect(inner, into: &out)
            default: break
            }
        }
    }

    private static func findUndefined(_ commands: [SedCommandNode],
                                      defined: Set<String>) -> String? {
        for command in commands {
            switch command {
            case .branch(_, let label),
                 .branchOnSubst(_, let label),
                 .branchOnNoSubst(_, let label):
                if let label, !label.isEmpty, !defined.contains(label) { return label }
            case .group(_, let inner):
                if let bad = findUndefined(inner, defined: defined) { return bad }
            default: break
            }
        }
        return nil
    }

    // MARK: - Recursive-descent parser

    // swiftlint:disable:next type_body_length
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
            let idx = pos + offset
            return idx < chars.count ? chars[idx] : nil
        }
        @discardableResult mutating func advance() -> Character {
            let char = chars[pos]
            pos += 1
            return char
        }
        mutating func skipBlankSeparators() {
            while !atEnd {
                let char = chars[pos]
                if char == " " || char == "\t" || char == "\n" || char == "\r" || char == ";" {
                    pos += 1
                } else if char == "#" {
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
                        let offset = readNumber()
                        range.end = .relative(offset: offset)
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
            let char = chars[pos]
            if char.isASCII, char.isNumber {
                let lineNum = readNumber()
                if !atEnd, chars[pos] == "~" {
                    pos += 1
                    let step = readNumber()
                    return .step(first: lineNum, step: step)
                }
                return .line(lineNum)
            }
            if char == "$" { pos += 1; return .last }
            if char == "/" || char == "\\" {
                // \cREGEXc — alternate delimiter
                let delim: Character
                if char == "\\" {
                    pos += 1
                    if atEnd { throw SedScriptError("expected pattern delimiter") }
                    delim = chars[pos]; pos += 1
                } else {
                    delim = "/"
                    pos += 1
                }
                let pattern = try readDelimited(until: delim, allowBracket: true)
                return .regex(pattern)
            }
            return nil
        }

        mutating func readNumber() -> Int {
            var number = 0
            while !atEnd, let digit = chars[pos].asciiValue, digit >= 0x30, digit <= 0x39 {
                number = number * 10 + Int(digit - 0x30)
                pos += 1
            }
            return number
        }

        /// Read until an unescaped `terminator` (consuming it). If
        /// `allowBracket`, `[..]` regions are passed through verbatim
        /// (the terminator inside brackets is literal).
        mutating func readDelimited(until terminator: Character,
                                    allowBracket: Bool) throws -> String {
            var out = ""
            var inBracket = false
            while !atEnd {
                let char = chars[pos]
                if char == terminator && !inBracket {
                    pos += 1
                    return out
                }
                if char == "\n" { break }
                if char == "\\", pos + 1 < chars.count {
                    let next = chars[pos + 1]
                    // Unescape the terminator (drop backslash); keep
                    // other escapes for the regex layer.
                    if next == terminator && !inBracket {
                        out.append(terminator); pos += 2; continue
                    }
                    out.append(char); out.append(next); pos += 2; continue
                }
                if allowBracket {
                    if char == "[" && !inBracket {
                        inBracket = true
                        out.append(char)
                        pos += 1
                        if !atEnd, chars[pos] == "^" {
                            out.append(chars[pos])
                            pos += 1
                        }
                        if !atEnd, chars[pos] == "]" {
                            out.append(chars[pos])
                            pos += 1
                        }
                        continue
                    }
                    if char == "]" && inBracket {
                        inBracket = false
                        out.append(char)
                        pos += 1
                        continue
                    }
                }
                out.append(char)
                pos += 1
            }
            throw SedScriptError("unterminated `\(terminator)`")
        }

        // Dispatcher for all 20+ sed commands; each case is a one-liner
        // delegating to the right `parseFoo`, so splitting would just
        // scatter the table.
        // swiftlint:disable:next cyclomatic_complexity function_body_length
        mutating func parseCommandBody(range: SedAddressRange) throws -> SedCommandNode? {
            guard !atEnd else { return nil }
            let char = chars[pos]
            switch char {
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
                let cmd = char
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
                let version = readUntilLineEnd()
                return .version(range, minVersion: version.isEmpty ? nil : version)
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
                throw SedScriptError("unknown command: '\(char)'")
            }
        }

        // Inline s/// flag-handling loop covers 9 distinct flags; per-flag
        // helpers would obscure their short-circuit / break behaviour.
        // swiftlint:disable:next cyclomatic_complexity
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
            var nth: Int?
            var writeFile: String?
            while !atEnd {
                let flag = chars[pos]
                if flag == ";" || flag == "\n" || flag == "}" { break }
                if flag == " " || flag == "\t" { pos += 1; continue }
                if flag == "g" { global = true; pos += 1; continue }
                if flag == "i" || flag == "I" { ignoreCase = true; pos += 1; continue }
                if flag == "p" { printOnMatch = true; pos += 1; continue }
                if flag.isASCII, flag.isNumber {
                    nth = readNumber(); continue
                }
                if flag == "w" {
                    pos += 1
                    skipHorizontalSpace()
                    writeFile = readUntilLineEnd()
                    break
                }
                if flag == "e" {
                    // Sandbox: silently ignore
                    pos += 1; continue
                }
                if flag == "M" || flag == "m" {
                    // multiline mode — accept but no-op for now
                    pos += 1; continue
                }
                throw SedScriptError("unknown s flag: \(flag)")
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
                let char = chars[pos]
                if char == terminator { pos += 1; return out }
                if char == "\n" {
                    throw SedScriptError("unterminated `s' command")
                }
                if char == "\\" && pos + 1 < chars.count {
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
                out.append(char); pos += 1
            }
            throw SedScriptError("unterminated `s' command")
        }

        mutating func parseTransliterate(range: SedAddressRange) throws -> SedCommandNode {
            guard !atEnd else { throw SedScriptError("expected delimiter after 'y'") }
            let delim = chars[pos]
            pos += 1
            let source = try readTransliterateOperand(until: delim)
            let dest = try readTransliterateOperand(until: delim)
            if source.count != dest.count {
                throw SedScriptError("transliteration sets must have same length")
            }
            // Allow only separators after y
            skipHorizontalSpace()
            if !atEnd {
                let next = chars[pos]
                if next != ";" && next != "\n" && next != "}" {
                    throw SedScriptError("extra text at the end of a transform command")
                }
            }
            return .transliterate(range, source: source, dest: dest)
        }

        mutating func readTransliterateOperand(until terminator: Character) throws -> String {
            var out = ""
            while !atEnd {
                let char = chars[pos]
                if char == terminator { pos += 1; return out }
                if char == "\n" { throw SedScriptError("unterminated y command") }
                if char == "\\" && pos + 1 < chars.count {
                    pos += 1
                    let next = chars[pos]
                    switch next {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "r": out += "\r"
                    case "\\": out += "\\"
                    default:
                        if next == terminator {
                            out.append(terminator)
                        } else {
                            out.append(next)
                        }
                    }
                    pos += 1
                } else {
                    out.append(char)
                    pos += 1
                }
            }
            throw SedScriptError("unterminated y command")
        }

        // Read a/i/c text. Supports `a\` followed by newline + text
        // (line continuation via trailing `\`), the GNU "a text" one-
        // liner, and `\n` / `\t` / `\r` escapes inside the text.
        // swiftlint:disable:next cyclomatic_complexity
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
                let char = chars[pos]
                if char == "\n" {
                    if text.hasSuffix("\\") {
                        text.removeLast()
                        text += "\n"
                        pos += 1
                        continue
                    }
                    break
                }
                if char == "\\" && pos + 1 < chars.count {
                    let next = chars[pos + 1]
                    switch next {
                    case "n": text += "\n"; pos += 2; continue
                    case "t": text += "\t"; pos += 2; continue
                    case "r": text += "\r"; pos += 2; continue
                    default: break
                    }
                }
                text.append(char); pos += 1
            }
            return text
        }

        mutating func readLabel() -> String? {
            skipHorizontalSpace()
            var name = ""
            while !atEnd {
                let char = chars[pos]
                if char == " " || char == "\t" || char == "\n"
                    || char == ";" || char == "}" || char == "{" {
                    break
                }
                name.append(char)
                pos += 1
            }
            return name.isEmpty ? nil : name
        }

        mutating func readFilename() -> String {
            skipHorizontalSpace()
            return readUntilLineEnd().trimmingCharacters(in: .whitespaces)
        }

        mutating func readUntilLineEnd() -> String {
            var line = ""
            while !atEnd, chars[pos] != "\n", chars[pos] != ";" {
                line.append(chars[pos])
                pos += 1
            }
            return line
        }
    }
}
