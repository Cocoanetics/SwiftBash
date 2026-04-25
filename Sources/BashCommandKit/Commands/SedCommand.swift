import ArgumentParser
import BashInterpreter
import Foundation

/// `sed [-n] [-E] [-i] [-e PROGRAM]... [PROGRAM] [FILE...]` —
/// pragmatic stream-editor subset.
///
/// ### Supported actions (with optional address)
/// - `s/PAT/REP/[gp]` — substitute (`g` global, `p` print on match)
/// - `d` — delete the pattern space (skip auto-print)
/// - `p` — print the pattern space immediately
///
/// ### Supported addresses
/// - `N` — only on line number N (1-based)
/// - `$` — only on the last line
/// - `/REGEX/` — only on lines matching REGEX
///
/// ### Flags
/// - `-n` / `--quiet` — suppress automatic printing of the pattern space
/// - `-E` / `--extended-regexp` — accepted; we always parse as ERE
/// - `-e PROGRAM` — append a program (repeatable; concatenated with `\n`)
/// - `-i` / `--in-place` — rewrite each input file in place
///
/// ### Regex flavour
/// All patterns are interpreted as `NSRegularExpression` ERE — we do
/// **not** translate POSIX BRE escapes. Use `(...)` for groups, `+ ? |
/// { }` directly. Replacement strings use sed conventions: `\1`–`\9`
/// for back-references and `&` for the whole match.
///
/// ### Out of scope
/// Address ranges (`a,b`), `{ … }` blocks, hold-space (`h H g G x`),
/// labels (`: b t`), `q`, `=`, `r`, `w`. The `i` substitute flag
/// (case-insensitive on `s`). `-i.bak`-style backup suffix.
public struct SedCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sed",
        abstract: "Stream editor (pragmatic subset)."
    )

    @Option(name: [.customShort("e"), .customLong("expression")],
            parsing: .singleValue,
            help: "Append a program. May be repeated.")
    public var expressions: [String] = []

    @Argument(help: """
        When no -e was given, the first positional is the program; \
        the rest are files. Otherwise all positionals are files.
        """)
    public var positionals: [String] = []

    @Flag(name: [.customShort("n"), .customLong("quiet")],
          help: "Suppress automatic printing of the pattern space.")
    public var quiet: Bool = false

    @Flag(name: [.customShort("E"), .customLong("extended-regexp")],
          help: "Use extended regex (no-op; we always do).")
    public var extendedRegexp: Bool = false

    @Flag(name: [.customShort("i"), .customLong("in-place")],
          help: "Edit files in place.")
    public var inPlace: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        let programs: [String]
        let files: [String]
        if expressions.isEmpty {
            guard let first = positionals.first else {
                shell.stderr("sed: missing program\n")
                return ExitStatus(2)
            }
            programs = [first]
            files = Array(positionals.dropFirst())
        } else {
            programs = expressions
            files = positionals
        }
        let combined = programs.joined(separator: "\n")

        let script: [SedScriptCommand]
        do {
            script = try SedParser.parse(combined)
        } catch let err as SedParseError {
            shell.stderr("sed: \(err.message)\n")
            return ExitStatus(2)
        }

        if files.isEmpty {
            if inPlace {
                shell.stderr("sed: -i requires file arguments\n")
                return ExitStatus(2)
            }
            var lines: [String] = []
            for await line in shell.stdin.lines { lines.append(line) }
            let out = run(script: script, lines: lines)
            for line in out { shell.stdout(line + "\n") }
        } else {
            for f in files {
                let abs = shell.resolvePath(f)
                let data: Data
                do {
                    data = try await shell.fileSystem.readData(abs)
                } catch {
                    shell.stderr("sed: \(f): \(error)\n")
                    return .failure
                }
                let text = String(decoding: data, as: UTF8.self)
                let lines = SortCommand.splitLines(text)
                let out = run(script: script, lines: lines)
                if inPlace {
                    let joined = out.isEmpty
                        ? ""
                        : out.joined(separator: "\n") + "\n"
                    do {
                        try await shell.fileSystem.writeData(
                            Data(joined.utf8), to: abs, append: false)
                    } catch {
                        shell.stderr("sed: \(f): \(error)\n")
                        return .failure
                    }
                } else {
                    for line in out { shell.stdout(line + "\n") }
                }
            }
        }
        return .success
    }

    // MARK: Runner

    private func run(script: [SedScriptCommand],
                     lines: [String]) -> [String] {
        var out: [String] = []
        let lastIdx = lines.count - 1
        for (idx, original) in lines.enumerated() {
            var pattern = original
            var deleted = false
            for cmd in script {
                if !cmd.address.matches(lineNum: idx + 1,
                                        isLast: idx == lastIdx,
                                        line: pattern) {
                    continue
                }
                switch cmd.action {
                case .substitute(let rule):
                    let r = rule.apply(to: pattern)
                    pattern = r.replaced
                    if r.didMatch && rule.printOnSubstitute {
                        out.append(pattern)
                    }
                case .delete:
                    deleted = true
                case .print:
                    out.append(pattern)
                }
                if deleted { break }
            }
            if !deleted, !quiet {
                out.append(pattern)
            }
        }
        return out
    }

    // MARK: Script types

    struct SedScriptCommand {
        let address: SedAddress
        let action: SedAction
    }

    enum SedAddress {
        case any
        case lineNumber(Int)
        case lastLine
        case regex(NSRegularExpression)

        func matches(lineNum: Int, isLast: Bool, line: String) -> Bool {
            switch self {
            case .any: return true
            case .lineNumber(let n): return n == lineNum
            case .lastLine: return isLast
            case .regex(let re):
                let r = NSRange(line.startIndex..., in: line)
                return re.firstMatch(in: line, options: [], range: r) != nil
            }
        }
    }

    enum SedAction {
        case substitute(SedSubstitute)
        case delete
        case print
    }

    struct SedSubstitute {
        let regex: NSRegularExpression
        let template: String
        let global: Bool
        let printOnSubstitute: Bool

        struct Result {
            let replaced: String
            let didMatch: Bool
        }

        func apply(to line: String) -> Result {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matchCount = regex.numberOfMatches(
                in: line, options: [], range: full)
            if matchCount == 0 {
                return Result(replaced: line, didMatch: false)
            }
            if global {
                let out = regex.stringByReplacingMatches(
                    in: line, options: [],
                    range: full, withTemplate: template)
                return Result(replaced: out, didMatch: true)
            }
            // First-match-only: locate and splice.
            guard let m = regex.firstMatch(
                in: line, options: [], range: full) else {
                return Result(replaced: line, didMatch: false)
            }
            let head = ns.substring(with: NSRange(
                location: 0, length: m.range.location))
            let tailStart = m.range.location + m.range.length
            let tail = ns.substring(with: NSRange(
                location: tailStart, length: ns.length - tailStart))
            let body = regex.replacementString(
                for: m, in: line, offset: 0, template: template)
            return Result(replaced: head + body + tail, didMatch: true)
        }
    }
}

// MARK: - Parser

struct SedParseError: Error {
    let message: String
}

enum SedParser {

    static func parse(_ source: String) throws
        -> [SedCommand.SedScriptCommand]
    {
        var out: [SedCommand.SedScriptCommand] = []
        let chars = Array(source)
        var i = 0

        while i < chars.count {
            // Skip whitespace and command separators (`;`, `\n`).
            while i < chars.count,
                  chars[i] == " " || chars[i] == "\t"
                    || chars[i] == "\n" || chars[i] == ";" {
                i += 1
            }
            // Skip blank-line / trailing-separator no-ops.
            if i >= chars.count { break }

            let address = try parseAddress(chars, &i)
            // Whitespace between address and action.
            while i < chars.count,
                  chars[i] == " " || chars[i] == "\t" {
                i += 1
            }
            guard i < chars.count else {
                throw SedParseError(message: "missing action after address")
            }
            let action = try parseAction(chars, &i)
            out.append(SedCommand.SedScriptCommand(
                address: address, action: action))
        }
        return out
    }

    private static func parseAddress(_ chars: [Character], _ i: inout Int)
        throws -> SedCommand.SedAddress
    {
        guard i < chars.count else { return .any }
        let c = chars[i]
        if c.isASCII, c.isNumber {
            let start = i
            while i < chars.count, chars[i].isNumber { i += 1 }
            let n = Int(String(chars[start..<i])) ?? 0
            return .lineNumber(n)
        }
        if c == "$" {
            i += 1
            return .lastLine
        }
        if c == "/" {
            i += 1
            let pat = try readUntilUnescaped(chars, &i, terminator: "/")
            do {
                let re = try NSRegularExpression(pattern: pat, options: [])
                return .regex(re)
            } catch {
                throw SedParseError(
                    message: "invalid address regex: \(pat)")
            }
        }
        return .any
    }

    private static func parseAction(_ chars: [Character], _ i: inout Int)
        throws -> SedCommand.SedAction
    {
        let c = chars[i]
        switch c {
        case "s":
            i += 1
            guard i < chars.count, chars[i] == "/" else {
                throw SedParseError(
                    message: "expected `/` after `s`")
            }
            i += 1
            let pat = try readUntilUnescaped(
                chars, &i, terminator: "/")
            let rep = try readUntilUnescaped(
                chars, &i, terminator: "/")
            var global = false
            var printAfter = false
            while i < chars.count,
                  chars[i] != ";" && chars[i] != "\n" {
                let f = chars[i]
                if f == "g" { global = true; i += 1 }
                else if f == "p" { printAfter = true; i += 1 }
                else if f == " " || f == "\t" { i += 1 }
                else {
                    throw SedParseError(
                        message: "unknown s flag: \(f)")
                }
            }
            let re: NSRegularExpression
            do {
                re = try NSRegularExpression(pattern: pat, options: [])
            } catch {
                throw SedParseError(
                    message: "invalid s pattern: \(pat)")
            }
            let template = sedReplacementToNSTemplate(rep)
            return .substitute(SedCommand.SedSubstitute(
                regex: re,
                template: template,
                global: global,
                printOnSubstitute: printAfter))
        case "d":
            i += 1
            return .delete
        case "p":
            i += 1
            return .print
        default:
            throw SedParseError(message: "unknown action: \(c)")
        }
    }

    /// Read until an unescaped `terminator`, consuming the terminator.
    /// `\X` passes both characters through (so `\/` becomes part of the
    /// returned slice, untouched, for the regex layer to re-interpret).
    private static func readUntilUnescaped(_ chars: [Character],
                                           _ i: inout Int,
                                           terminator: Character) throws
        -> String
    {
        var out: [Character] = []
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                // Pass through the escape and the escaped char.
                if chars[i + 1] == terminator {
                    // Literal terminator → escaped, but in regex context
                    // we want bare terminator. Strip the backslash so
                    // `s/\///g` (replace `/` with empty) works.
                    out.append(terminator)
                } else {
                    out.append(c)
                    out.append(chars[i + 1])
                }
                i += 2
                continue
            }
            if c == terminator {
                i += 1
                return String(out)
            }
            out.append(c)
            i += 1
        }
        throw SedParseError(
            message: "unterminated `\(terminator)`")
    }

    /// Translate a sed replacement string into an
    /// `NSRegularExpression.replacementString(...)` template:
    ///
    /// - `\1`–`\9`  → `$1`–`$9`
    /// - `&`        → `$0`
    /// - `\&`       → literal `&`
    /// - `\\`       → `\\`  (still one literal backslash)
    /// - `$`        → `\$`  (escape NSRegex variable syntax)
    static func sedReplacementToNSTemplate(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n.isASCII, n.isNumber {
                    out += "$\(n)"
                    i += 2
                    continue
                }
                if n == "&" {
                    out += "&"
                    i += 2
                    continue
                }
                if n == "\\" {
                    out += "\\\\"
                    i += 2
                    continue
                }
                // Unknown \X → output X literally.
                out.append(n)
                i += 2
                continue
            }
            if c == "&" {
                out += "$0"
            } else if c == "$" {
                out += "\\$"
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }
}
