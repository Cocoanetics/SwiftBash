import Foundation

/// `echo [-n] [-e] [-E] [--] ARGS...`
///
/// Prints its arguments separated by a single space.
///
/// - `-n` — suppress trailing newline.
/// - `-e` — interpret backslash escapes (`\n` `\t` `\r` `\b` `\f` `\v`
///   `\a` `\\` `\0NNN` octal `\xHH` hex, `\c` to halt output).
///   Disabled by default.
/// - `-E` — explicitly disable escape interpretation (overrides `-e`,
///   matches GNU `echo`).
/// - `--` — ends option parsing.
///
/// Only options that appear contiguously at the start (before `--` or
/// any data argument) are recognised; later flag-shaped tokens pass
/// through as data. Combined short flags like `-ne` / `-en` are
/// supported.
public struct EchoCommand: Command {
    public let name = "echo"

    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var args = Array(argv.dropFirst())
        var newline = true
        var interpret = false

        optionLoop: while let first = args.first {
            if first == "--" { args.removeFirst(); break optionLoop }
            // Combined short flags like -ne / -en / -nE.
            if first.hasPrefix("-") && first.count > 1
                && first.dropFirst().allSatisfy({ "neE".contains($0) }) {
                for c in first.dropFirst() {
                    switch c {
                    case "n": newline = false
                    case "e": interpret = true
                    case "E": interpret = false
                    default: break
                    }
                }
                args.removeFirst(); continue
            }
            break optionLoop
        }

        var pieces: [String] = []
        var stopAfter = false
        for a in args {
            if interpret {
                let (s, stop) = Self.expandEscapes(a)
                pieces.append(s)
                if stop { stopAfter = true; break }
            } else {
                pieces.append(a)
            }
        }

        let joined = pieces.joined(separator: " ")
        let suffix = (newline && !stopAfter) ? "\n" : ""
        Shell.current.stdout(joined + suffix)
        return .success
    }

    /// Process backslash escapes for `-e`. Returns the expanded string
    /// and whether `\c` was encountered (suppresses the rest of the
    /// output, including the trailing newline).
    static func expandEscapes(_ s: String) -> (String, Bool) {
        var out = ""
        var stop = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "n": out += "\n"; i += 2
                case "t": out += "\t"; i += 2
                case "r": out += "\r"; i += 2
                case "b": out += "\u{08}"; i += 2
                case "f": out += "\u{0C}"; i += 2
                case "v": out += "\u{0B}"; i += 2
                case "a": out += "\u{07}"; i += 2
                case "\\": out += "\\"; i += 2
                case "c": stop = true; i = chars.count
                case "0":
                    i += 2
                    var oct = ""
                    while oct.count < 3, i < chars.count,
                          let v = chars[i].asciiValue, v >= 0x30, v <= 0x37 {
                        oct.append(chars[i]); i += 1
                    }
                    if let n = UInt32(oct, radix: 8), let u = Unicode.Scalar(n) {
                        out.append(Character(u))
                    }
                case "x":
                    i += 2
                    var hex = ""
                    while hex.count < 2, i < chars.count, chars[i].isHexDigit {
                        hex.append(chars[i]); i += 1
                    }
                    if let n = UInt32(hex, radix: 16), let u = Unicode.Scalar(n) {
                        out.append(Character(u))
                    }
                default:
                    out += "\\"; out.append(n); i += 2
                }
            } else {
                out.append(c); i += 1
            }
        }
        return (out, stop)
    }
}
