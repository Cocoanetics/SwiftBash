import Foundation

extension PrintfCommand {

    /// Parse one `%[flags][width][.precision]conv` starting at `chars[i]`
    /// (which must be `%`). Returns the directive and the index just
    /// past the conversion character, or `nil` if the format is
    /// malformed (e.g. `%` at end of string).
    func parseDirective(_ chars: [Character], from start: Int)
        -> (Directive, Int)? {
        var index = start + 1
        var flags = ""
        while index < chars.count, "-+ #0".contains(chars[index]) {
            flags.append(chars[index])
            index += 1
        }
        var width = ""
        if index < chars.count, chars[index] == "*" {
            width = "*"
            index += 1
        } else {
            while index < chars.count, chars[index].isNumber {
                width.append(chars[index])
                index += 1
            }
        }
        var precision: String?
        if index < chars.count, chars[index] == "." {
            index += 1
            var precDigits = ""
            if index < chars.count, chars[index] == "*" {
                precDigits = "*"
                index += 1
            } else {
                while index < chars.count, chars[index].isNumber {
                    precDigits.append(chars[index])
                    index += 1
                }
            }
            precision = precDigits
        }
        guard index < chars.count else { return nil }
        let conv = chars[index]
        return (Directive(flags: flags, width: width,
                          precision: precision, conv: conv), index + 1)
    }

    // Dispatch over the full printf conversion table (s/c/d/i/u/o/x/X/
    // f/e/E/g/G/b/q). Per-conversion helpers exist for the heavy
    // cases (`formatInt`, `formatFloat`); the top-level switch is
    // intrinsically wide.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func applyDirective(_ directive: Directive, arg: String,
                        output: inout String) {
        switch directive.conv {
        case "s":
            let truncated: String
            if let precStr = directive.precision, let precN = Int(precStr), precN < arg.count {
                truncated = String(arg.prefix(precN))
            } else {
                truncated = arg
            }
            output += pad(truncated, width: directive.width,
                          leftAlign: directive.flags.contains("-"),
                          zero: false)

        case "c":
            let firstChar = arg.first.map(String.init) ?? ""
            output += pad(firstChar, width: directive.width,
                          leftAlign: directive.flags.contains("-"),
                          zero: false)

        case "d", "i":
            output += formatInt(arg, dir: directive, base: 10, upper: false)

        case "u":
            output += formatInt(arg, dir: directive, base: 10, upper: false)

        case "o":
            output += formatInt(arg, dir: directive, base: 8, upper: false)

        case "x":
            output += formatInt(arg, dir: directive, base: 16, upper: false)

        case "X":
            output += formatInt(arg, dir: directive, base: 16, upper: true)

        case "f", "e", "E", "g", "G":
            output += formatFloat(arg, dir: directive)

        case "b":
            // Process backslash escapes in the arg, then apply
            // width/precision (precision = max chars).
            var expanded = ""
            let argChars = Array(arg)
            var idx = 0
            outer: while idx < argChars.count {
                if argChars[idx] == "\\" {
                    // %b also recognises `\c` to stop further output.
                    if idx + 1 < argChars.count, argChars[idx + 1] == "c" { break outer }
                    let (text, adv) = expandBackslash(argChars, from: idx)
                    expanded += text
                    idx += adv
                } else {
                    expanded.append(argChars[idx])
                    idx += 1
                }
            }
            if let precStr = directive.precision, let precN = Int(precStr), precN < expanded.count {
                expanded = String(expanded.prefix(precN))
            }
            output += pad(expanded, width: directive.width,
                          leftAlign: directive.flags.contains("-"), zero: false)

        case "q":
            output += pad(shellQuote(arg), width: directive.width,
                          leftAlign: directive.flags.contains("-"), zero: false)

        default:
            // Unknown conversion — emit the directive literally so the
            // user can see what went wrong.
            output += "%\(directive.flags)\(directive.width)" +
                     (directive.precision.map { ".\($0)" } ?? "") +
                     String(directive.conv)
        }
    }

    func formatInt(_ arg: String, dir directive: Directive,
                   base: Int, upper: Bool) -> String {
        let intVal = parseIntArg(arg)
        var body: String
        let absVal: UInt64
        let negative: Bool
        if base == 10 {
            negative = intVal < 0
            absVal = negative ? UInt64(-(intVal + 1)) + 1 : UInt64(intVal)
        } else {
            negative = false
            absVal = UInt64(bitPattern: Int64(intVal))
        }
        body = String(absVal, radix: base, uppercase: upper)

        // Precision = minimum digit count (left-pad with zeros).
        if let precStr = directive.precision, let precN = Int(precStr), precN > body.count {
            body = String(repeating: "0", count: precN - body.count) + body
        }

        var sign = ""
        if base == 10 {
            if negative {
                sign = "-"
            } else if directive.flags.contains("+") {
                sign = "+"
            } else if directive.flags.contains(" ") {
                sign = " "
            }
        }

        var prefix = ""
        if directive.flags.contains("#") {
            if base == 8, !body.hasPrefix("0") {
                prefix = "0"
            } else if base == 16, intVal != 0 {
                prefix = upper ? "0X" : "0x"
            }
        }

        let assembled = sign + prefix + body
        let zeroPad = directive.flags.contains("0") && directive.precision == nil
                      && !directive.flags.contains("-")
        if zeroPad, let width = Int(directive.width), width > assembled.count {
            return sign + prefix + String(repeating: "0",
                count: width - sign.count - prefix.count - body.count) + body
        }
        return pad(assembled, width: directive.width,
                   leftAlign: directive.flags.contains("-"), zero: false)
    }

    func formatFloat(_ arg: String, dir directive: Directive) -> String {
        let value = Double(arg) ?? 0
        // Reconstruct a C format string and let `String(format:)` do the
        // real work — width/precision/flags are POSIX-standard for floats.
        var spec = "%"
        spec += directive.flags
        spec += directive.width
        if let precStr = directive.precision { spec += ".\(precStr)" }
        spec.append(directive.conv)
        return String(format: spec, value)
    }
}
