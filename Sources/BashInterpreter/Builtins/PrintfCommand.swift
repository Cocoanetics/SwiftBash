import Foundation

/// `printf [-v VAR] FORMAT [ARG ...]` — formatted output.
///
/// Walks `FORMAT` once, expanding backslash escapes and `%`-directives
/// inline. If the args outnumber the directives, the format is *reused*
/// from the start until the args are drained — bash semantics that
/// makes `printf "%s\n" a b c` print three lines from one format.
///
/// Supported directives:
/// - `%s` — string
/// - `%c` — first character of arg
/// - `%d` / `%i` / `%u` — decimal integer
/// - `%o` — octal, `%x` / `%X` — hex
/// - `%f` / `%e` / `%E` / `%g` / `%G` — floating point
/// - `%b` — string with backslash escapes processed
/// - `%q` — argument quoted for shell re-input
/// - `%%` — literal `%`
///
/// Flags (`-+ #0`), width, and precision are honoured. `*` may stand
/// in for width or precision and consumes the next arg as an integer.
///
/// `-v VAR` redirects output to a shell variable instead of stdout.
public struct PrintfCommand: Command {
    public let name = "printf"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var i = 1
        var assignTo: String? = nil

        while i < argv.count {
            let a = argv[i]
            if a == "-v" {
                guard i + 1 < argv.count else {
                    Shell.bashCurrent.stderr("printf: -v: option requires an argument\n")
                    return ExitStatus(2)
                }
                assignTo = argv[i + 1]
                i += 2
            } else if a == "--" {
                i += 1
                break
            } else {
                break
            }
        }

        guard i < argv.count else {
            Shell.bashCurrent.stderr("printf: usage: printf [-v var] format [arguments]\n")
            return ExitStatus(2)
        }

        let format = argv[i]
        let args = Array(argv[(i + 1)...])

        var output = ""
        var argIdx = 0
        // Reuse the format string until args are drained, but only if
        // the format actually consumed an arg this pass — otherwise
        // we'd loop forever on a pure-literal format.
        repeat {
            let pass = formatOnce(format: format, args: args,
                                  startAt: argIdx, output: &output)
            if !pass.consumedAny { break }
            argIdx = pass.nextArgIdx
        } while argIdx < args.count

        if let assignTo {
            Shell.bashCurrent.environment[assignTo] = output
        } else {
            Shell.bashCurrent.stdout(output)
        }
        return .success
    }

    // MARK: One pass over the format string

    private struct PassResult {
        var nextArgIdx: Int
        var consumedAny: Bool
    }

    private func formatOnce(format: String, args: [String],
                            startAt: Int, output: inout String) -> PassResult {
        let chars = Array(format)
        var i = 0
        var argIdx = startAt
        var consumedAny = false

        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                let (text, adv) = expandBackslash(chars, from: i)
                output += text
                i += adv
            } else if c == "%" {
                guard let (dir, nextI) = parseDirective(chars, from: i) else {
                    // Malformed directive (e.g. trailing `%`) — emit literal.
                    output.append("%")
                    i += 1
                    continue
                }
                if dir.conv == "%" {
                    output.append("%")
                    i = nextI
                    continue
                }
                // `*` width / precision pulls an int from the args.
                var d = dir
                if d.width == "*" {
                    d.width = "\(intArg(args, argIdx))"
                    argIdx += 1
                }
                if d.precision == "*" {
                    d.precision = "\(intArg(args, argIdx))"
                    argIdx += 1
                }
                let arg = argIdx < args.count ? args[argIdx] : ""
                applyDirective(d, arg: arg, output: &output)
                argIdx += 1
                consumedAny = true
                i = nextI
            } else {
                output.append(c)
                i += 1
            }
        }

        return PassResult(nextArgIdx: argIdx, consumedAny: consumedAny)
    }

    // MARK: Directive parsing

    private struct Directive {
        var flags: String
        var width: String
        var precision: String?
        var conv: Character
    }

    /// Parse one `%[flags][width][.precision]conv` starting at `chars[i]`
    /// (which must be `%`). Returns the directive and the index just
    /// past the conversion character, or `nil` if the format is
    /// malformed (e.g. `%` at end of string).
    private func parseDirective(_ chars: [Character], from start: Int)
        -> (Directive, Int)?
    {
        var i = start + 1
        var flags = ""
        while i < chars.count, "-+ #0".contains(chars[i]) {
            flags.append(chars[i])
            i += 1
        }
        var width = ""
        if i < chars.count, chars[i] == "*" {
            width = "*"
            i += 1
        } else {
            while i < chars.count, chars[i].isNumber {
                width.append(chars[i])
                i += 1
            }
        }
        var precision: String? = nil
        if i < chars.count, chars[i] == "." {
            i += 1
            var p = ""
            if i < chars.count, chars[i] == "*" {
                p = "*"
                i += 1
            } else {
                while i < chars.count, chars[i].isNumber {
                    p.append(chars[i])
                    i += 1
                }
            }
            precision = p
        }
        guard i < chars.count else { return nil }
        let conv = chars[i]
        return (Directive(flags: flags, width: width,
                          precision: precision, conv: conv), i + 1)
    }

    // MARK: Directive application

    private func applyDirective(_ d: Directive, arg: String,
                                output: inout String) {
        switch d.conv {
        case "s":
            let truncated: String
            if let p = d.precision, let n = Int(p), n < arg.count {
                truncated = String(arg.prefix(n))
            } else {
                truncated = arg
            }
            output += pad(truncated, width: d.width, leftAlign: d.flags.contains("-"),
                          zero: false)

        case "c":
            let ch = arg.first.map(String.init) ?? ""
            output += pad(ch, width: d.width, leftAlign: d.flags.contains("-"),
                          zero: false)

        case "d", "i":
            output += formatInt(arg, dir: d, base: 10, upper: false)

        case "u":
            output += formatInt(arg, dir: d, base: 10, upper: false)

        case "o":
            output += formatInt(arg, dir: d, base: 8, upper: false)

        case "x":
            output += formatInt(arg, dir: d, base: 16, upper: false)

        case "X":
            output += formatInt(arg, dir: d, base: 16, upper: true)

        case "f", "e", "E", "g", "G":
            output += formatFloat(arg, dir: d)

        case "b":
            // Process backslash escapes in the arg, then apply
            // width/precision (precision = max chars).
            var expanded = ""
            let ac = Array(arg)
            var j = 0
            outer: while j < ac.count {
                if ac[j] == "\\" {
                    // %b also recognises `\c` to stop further output.
                    if j + 1 < ac.count, ac[j + 1] == "c" { break outer }
                    let (t, adv) = expandBackslash(ac, from: j)
                    expanded += t
                    j += adv
                } else {
                    expanded.append(ac[j])
                    j += 1
                }
            }
            if let p = d.precision, let n = Int(p), n < expanded.count {
                expanded = String(expanded.prefix(n))
            }
            output += pad(expanded, width: d.width,
                          leftAlign: d.flags.contains("-"), zero: false)

        case "q":
            output += pad(shellQuote(arg), width: d.width,
                          leftAlign: d.flags.contains("-"), zero: false)

        default:
            // Unknown conversion — emit the directive literally so the
            // user can see what went wrong.
            output += "%\(d.flags)\(d.width)" +
                     (d.precision.map { ".\($0)" } ?? "") +
                     String(d.conv)
        }
    }

    private func formatInt(_ arg: String, dir d: Directive,
                           base: Int, upper: Bool) -> String {
        let n = parseIntArg(arg)
        var body: String
        let abs: UInt64
        let negative: Bool
        if base == 10 {
            negative = n < 0
            abs = negative ? UInt64(-(n + 1)) + 1 : UInt64(n)
        } else {
            negative = false
            abs = UInt64(bitPattern: Int64(n))
        }
        body = String(abs, radix: base, uppercase: upper)

        // Precision = minimum digit count (left-pad with zeros).
        if let p = d.precision, let pn = Int(p), pn > body.count {
            body = String(repeating: "0", count: pn - body.count) + body
        }

        var sign = ""
        if base == 10 {
            if negative { sign = "-" }
            else if d.flags.contains("+") { sign = "+" }
            else if d.flags.contains(" ") { sign = " " }
        }

        var prefix = ""
        if d.flags.contains("#") {
            if base == 8, !body.hasPrefix("0") { prefix = "0" }
            else if base == 16, n != 0 { prefix = upper ? "0X" : "0x" }
        }

        let assembled = sign + prefix + body
        let zeroPad = d.flags.contains("0") && d.precision == nil
                      && !d.flags.contains("-")
        if zeroPad, let w = Int(d.width), w > assembled.count {
            return sign + prefix + String(repeating: "0",
                count: w - sign.count - prefix.count - body.count) + body
        }
        return pad(assembled, width: d.width,
                   leftAlign: d.flags.contains("-"), zero: false)
    }

    private func formatFloat(_ arg: String, dir d: Directive) -> String {
        let v = Double(arg) ?? 0
        // Reconstruct a C format string and let `String(format:)` do the
        // real work — width/precision/flags are POSIX-standard for floats.
        var spec = "%"
        spec += d.flags
        spec += d.width
        if let p = d.precision { spec += ".\(p)" }
        spec.append(d.conv)
        return String(format: spec, v)
    }

    private func parseIntArg(_ s: String) -> Int {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        // Bash printf accepts `'X` / `"X` and uses the char's code-point.
        if trimmed.first == "'" || trimmed.first == "\"" {
            let rest = trimmed.dropFirst()
            if let scalar = rest.unicodeScalars.first {
                return Int(scalar.value)
            }
            return 0
        }
        // Honour `0x…` hex and `0…` octal prefixes (bash does).
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return Int(trimmed.dropFirst(2), radix: 16) ?? 0
        }
        if trimmed.count > 1, trimmed.hasPrefix("0"),
           trimmed.allSatisfy({ "01234567".contains($0) }) {
            return Int(trimmed, radix: 8) ?? 0
        }
        return Int(trimmed) ?? 0
    }

    // MARK: Helpers

    private func intArg(_ args: [String], _ idx: Int) -> Int {
        guard idx < args.count else { return 0 }
        return Int(args[idx]) ?? 0
    }

    private func pad(_ s: String, width: String,
                     leftAlign: Bool, zero: Bool) -> String {
        guard let w = Int(width), w > s.count else { return s }
        let padCh: Character = zero ? "0" : " "
        let padding = String(repeating: padCh, count: w - s.count)
        return leftAlign ? s + padding : padding + s
    }

    /// Shell-quote `s` so it reads back as the same word. Single-quote
    /// when possible; embedded `'` becomes `'\''`. Empty stays as `''`.
    private func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        // Already-safe? POSIX portable filename character set + a few extras.
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if s.allSatisfy({ safe.contains($0) }) { return s }
        var quoted = "'"
        for ch in s {
            if ch == "'" { quoted += "'\\''" }
            else { quoted.append(ch) }
        }
        quoted += "'"
        return quoted
    }

    /// Expand the backslash escape at `chars[i]` (must be `\\`). Returns
    /// the substituted text and how many input chars were consumed
    /// (always at least 1).
    private func expandBackslash(_ chars: [Character], from i: Int)
        -> (String, Int)
    {
        guard i + 1 < chars.count else { return ("\\", 1) }
        let c = chars[i + 1]
        switch c {
        case "a": return ("\u{07}", 2)
        case "b": return ("\u{08}", 2)
        case "e", "E": return ("\u{1B}", 2)
        case "f": return ("\u{0C}", 2)
        case "n": return ("\n", 2)
        case "r": return ("\r", 2)
        case "t": return ("\t", 2)
        case "v": return ("\u{0B}", 2)
        case "\\": return ("\\", 2)
        case "\"": return ("\"", 2)
        case "'": return ("'", 2)
        case "?": return ("?", 2)
        case "0":
            // `\0NNN` — up to 3 octal digits after the leading `0`.
            var n = 0
            var len = 2
            for _ in 0..<3 {
                let pos = i + len
                guard pos < chars.count,
                      let v = chars[pos].hexDigitValue, v < 8 else { break }
                n = n * 8 + v
                len += 1
            }
            return (scalar(n), len)
        case "x":
            // `\xHH` — 1 or 2 hex digits.
            var n = 0
            var len = 2
            for _ in 0..<2 {
                let pos = i + len
                guard pos < chars.count,
                      let v = chars[pos].hexDigitValue else { break }
                n = n * 16 + v
                len += 1
            }
            if len == 2 { return ("\\x", 2) }
            return (scalar(n), len)
        case "u":
            return readUnicode(chars, after: i + 2, digits: 4, escapeLen: 2)
        case "U":
            return readUnicode(chars, after: i + 2, digits: 8, escapeLen: 2)
        default:
            return ("\\\(c)", 2)
        }
    }

    private func readUnicode(_ chars: [Character], after start: Int,
                             digits: Int, escapeLen: Int) -> (String, Int) {
        var n = 0
        var len = escapeLen
        for _ in 0..<digits {
            let pos = start + (len - escapeLen)
            guard pos < chars.count,
                  let v = chars[pos].hexDigitValue else { break }
            n = n * 16 + v
            len += 1
        }
        if len == escapeLen {
            return ("\\\(chars[start - 1])", escapeLen)
        }
        return (scalar(n), len)
    }

    private func scalar(_ n: Int) -> String {
        UnicodeScalar(n).map { String($0) } ?? ""
    }
}
