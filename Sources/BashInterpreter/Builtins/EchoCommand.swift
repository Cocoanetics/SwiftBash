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

    // Option parse + per-arg escape expansion + joined output assembly;
    // splitting into helpers would scatter the bundled-short-flag rule.
    // swiftlint:disable:next cyclomatic_complexity
    public func run(_ argv: [String]) async throws -> ExitStatus {
        var args = Array(argv.dropFirst())
        var newline = true
        var interpret = false

        optionLoop: while let first = args.first {
            if first == "--" { args.removeFirst(); break optionLoop }
            // Combined short flags like -ne / -en / -nE.
            if first.hasPrefix("-") && first.count > 1
                && first.dropFirst().allSatisfy({ "neE".contains($0) }) {
                for char in first.dropFirst() {
                    switch char {
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
        for arg in args {
            if interpret {
                let (text, stop) = Self.expandEscapes(arg)
                pieces.append(text)
                if stop { stopAfter = true; break }
            } else {
                pieces.append(arg)
            }
        }

        let joined = pieces.joined(separator: " ")
        let suffix = (newline && !stopAfter) ? "\n" : ""
        Shell.bashCurrent.stdout(joined + suffix)
        return .success
    }

    // Process backslash escapes for `-e`. Returns the expanded string
    // and whether `\c` was encountered (suppresses the rest of the
    // output, including the trailing newline).
    //
    // Flat dispatch over the supported escape table; one case per
    // escape character.
    // swiftlint:disable:next cyclomatic_complexity
    static func expandEscapes(_ source: String) -> (String, Bool) {
        var out = ""
        var stop = false
        let chars = Array(source)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count {
                let nextChar = chars[index + 1]
                switch nextChar {
                case "n": out += "\n"; index += 2
                case "t": out += "\t"; index += 2
                case "r": out += "\r"; index += 2
                case "b": out += "\u{08}"; index += 2
                case "f": out += "\u{0C}"; index += 2
                case "v": out += "\u{0B}"; index += 2
                case "a": out += "\u{07}"; index += 2
                case "\\": out += "\\"; index += 2
                case "c": stop = true; index = chars.count
                case "0":
                    index += 2
                    var oct = ""
                    while oct.count < 3, index < chars.count,
                          let asciiValue = chars[index].asciiValue,
                          asciiValue >= 0x30, asciiValue <= 0x37 {
                        oct.append(chars[index]); index += 1
                    }
                    if let num = UInt32(oct, radix: 8),
                       let scalar = Unicode.Scalar(num) {
                        out.append(Character(scalar))
                    }
                case "x":
                    index += 2
                    var hex = ""
                    while hex.count < 2, index < chars.count, chars[index].isHexDigit {
                        hex.append(chars[index]); index += 1
                    }
                    if let num = UInt32(hex, radix: 16),
                       let scalar = Unicode.Scalar(num) {
                        out.append(Character(scalar))
                    }
                default:
                    out += "\\"; out.append(nextChar); index += 2
                }
            } else {
                out.append(char); index += 1
            }
        }
        return (out, stop)
    }
}
