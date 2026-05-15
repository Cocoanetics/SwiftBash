import Foundation

/// AWK printf / sprintf formatting. Supports the POSIX format
/// specifiers (`% [flags] [width] [.precision] [length] conv`),
/// positional arguments (`%n$`), `*` for width / precision drawn
/// from arg list, and the standard escape sequences in the format
/// string itself.
enum AwkPrintf {

    private static let maxWidth = 10_000

    // POSIX printf has many conversion characters and an escape table;
    // the long inline switch reads better than fragmenting per-spec.
    // swiftlint:disable:next cyclomatic_complexity
    static func format(_ fmt: String, values: [AwkValue]) -> String {
        let chars = Array(fmt)
        var out = ""
        var valueIdx = 0          // sequential value index
        var cursor = 0
        while cursor < chars.count {
            let char = chars[cursor]
            if char == "%" && cursor + 1 < chars.count {
                let parsed = parseSpec(
                    chars, start: cursor + 1,
                    valueIdx: valueIdx, values: values)
                let spec = parsed.spec
                let pickIdx = spec.positional ?? parsed.idxAfter
                let value = pickIdx < values.count ? values[pickIdx] : AwkValue.empty
                out += renderSpec(spec, value: value)
                valueIdx = parsed.idxAfter
                if spec.positional == nil && spec.conv != "%" {
                    valueIdx += 1
                }
                cursor = parsed.endPos
            } else if char == "\\" && cursor + 1 < chars.count {
                switch chars[cursor + 1] {
                case "n": out += "\n"; cursor += 2
                case "t": out += "\t"; cursor += 2
                case "r": out += "\r"; cursor += 2
                case "\\": out += "\\"; cursor += 2
                case "/": out += "/"; cursor += 2
                case "\"": out += "\""; cursor += 2
                case "a": out += "\u{07}"; cursor += 2
                case "b": out += "\u{08}"; cursor += 2
                case "f": out += "\u{0C}"; cursor += 2
                case "v": out += "\u{0B}"; cursor += 2
                default: out.append(chars[cursor + 1]); cursor += 2
                }
            } else {
                out.append(char)
                cursor += 1
            }
        }
        return out
    }

    private struct Spec {
        var flags: String = ""
        var width: Int?
        var precision: Int?
        var conv: Character = "s"
        var positional: Int?
    }

    private struct ParseResult {
        let spec: Spec
        let endPos: Int      // position just past the conversion char
        let idxAfter: Int    // updated value index (for `*` consumption)
    }

    // Five-phase spec parser (position, flags, width, precision,
    // length+conv). Each phase mutates `cursor` and `spec`; splitting
    // would force a 5-tuple state struct.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func parseSpec(_ chars: [Character], start: Int,
                                  valueIdx: Int, values: [AwkValue]) -> ParseResult {
        var spec = Spec()
        var cursor = start
        var idx = valueIdx

        // Positional arg: %n$
        let posStart = cursor
        while cursor < chars.count,
              chars[cursor].isASCII,
              chars[cursor].isNumber {
            cursor += 1
        }
        if cursor > posStart && cursor < chars.count && chars[cursor] == "$" {
            spec.positional = (Int(String(chars[posStart..<cursor])) ?? 1) - 1
            cursor += 1
        } else {
            cursor = posStart
        }

        while cursor < chars.count, "-+ #0".contains(chars[cursor]) {
            spec.flags.append(chars[cursor])
            cursor += 1
        }

        if cursor < chars.count && chars[cursor] == "*" {
            cursor += 1
            if idx < values.count {
                let width = Int(values[idx].asNumber)
                idx += 1
                if width < 0 {
                    spec.flags.append("-")
                    spec.width = min(-width, maxWidth)
                } else {
                    spec.width = min(width, maxWidth)
                }
            }
        } else {
            var widthDigits = ""
            while cursor < chars.count,
                  chars[cursor].isASCII,
                  chars[cursor].isNumber {
                widthDigits.append(chars[cursor])
                cursor += 1
            }
            if !widthDigits.isEmpty {
                spec.width = min(Int(widthDigits) ?? 0, maxWidth)
            }
        }

        if cursor < chars.count && chars[cursor] == "." {
            cursor += 1
            if cursor < chars.count && chars[cursor] == "*" {
                cursor += 1
                if idx < values.count {
                    spec.precision = min(max(0, Int(values[idx].asNumber)), maxWidth)
                    idx += 1
                }
            } else {
                var precDigits = ""
                while cursor < chars.count,
                      chars[cursor].isASCII,
                      chars[cursor].isNumber {
                    precDigits.append(chars[cursor])
                    cursor += 1
                }
                spec.precision = min(Int(precDigits) ?? 0, maxWidth)
            }
        }

        // Skip length modifiers (l/ll/h/hh/z/j) — ignored.
        while cursor < chars.count, "lhzj".contains(chars[cursor]) { cursor += 1 }

        if cursor < chars.count {
            spec.conv = chars[cursor]
            cursor += 1
        }
        return ParseResult(spec: spec, endPos: cursor, idxAfter: idx)
    }

    // 13-way conversion table; per-case helpers would obscure the
    // POSIX-printf layout.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func renderSpec(_ spec: Spec, value: AwkValue) -> String {
        switch spec.conv {
        case "%":
            return "%"
        case "s":
            var text = value.asString
            if let prec = spec.precision { text = String(text.prefix(prec)) }
            return pad(text, width: spec.width, leftAlign: spec.flags.contains("-"))
        case "c":
            if case .number(let number) = value,
               let scalar = Unicode.Scalar(UInt32(Int(number) & 0xFF)) {
                return pad(String(Character(scalar)),
                           width: spec.width, leftAlign: spec.flags.contains("-"))
            }
            let text = value.asString
            return pad(String(text.first.map { String($0) } ?? ""),
                       width: spec.width, leftAlign: spec.flags.contains("-"))
        case "d", "i":
            let number = Int64(value.asNumber.rounded(.towardZero))
            return formatInteger(number, base: 10, upper: false, spec: spec)
        case "o":
            let number = Int64(value.asNumber.rounded(.towardZero))
            return formatInteger(number, base: 8, upper: false, spec: spec)
        case "x":
            let number = Int64(value.asNumber.rounded(.towardZero))
            return formatInteger(number, base: 16, upper: false, spec: spec)
        case "X":
            let number = Int64(value.asNumber.rounded(.towardZero))
            return formatInteger(number, base: 16, upper: true, spec: spec)
        case "u":
            let unsigned = UInt64(bitPattern: Int64(value.asNumber.rounded(.towardZero)))
            return formatInteger(Int64(bitPattern: unsigned),
                                 base: 10, upper: false, spec: spec)
        case "f", "F":
            let number = value.asNumber
            let prec = spec.precision ?? 6
            let formatted = String(format: "%.\(prec)f", number)
            return padNumeric(formatted, spec: spec)
        case "e", "E":
            let number = value.asNumber
            let prec = spec.precision ?? 6
            var formatted = String(format: "%.\(prec)\(spec.conv)", number)
            if spec.conv == "E" { formatted = formatted.uppercased() }
            return padNumeric(formatted, spec: spec)
        case "g", "G":
            let number = value.asNumber
            let prec = spec.precision ?? 6
            let formatted = String(format: "%.\(prec)\(spec.conv)", number)
            return padNumeric(formatted, spec: spec)
        default:
            return "%" + String(spec.conv)
        }
    }

    // Sign, precision-padding and width-padding are deeply intertwined
    // for printf's %d/%o/%x; splitting would just chain the branches.
    // swiftlint:disable:next cyclomatic_complexity
    private static func formatInteger(_ number: Int64, base: Int,
                                      upper: Bool, spec: Spec) -> String {
        var digits: String
        let absVal = number < 0 ? UInt64(bitPattern: Int64(-number)) : UInt64(number)
        switch base {
        case 8: digits = String(absVal, radix: 8)
        case 16: digits = String(absVal, radix: 16, uppercase: upper)
        default: digits = String(absVal, radix: 10)
        }
        if let prec = spec.precision {
            while digits.count < prec { digits = "0" + digits }
        }
        var sign = ""
        if number < 0 {
            sign = "-"
        } else if spec.flags.contains("+") {
            sign = "+"
        } else if spec.flags.contains(" ") {
            sign = " "
        }
        var result = sign + digits
        if let width = spec.width {
            if spec.flags.contains("-") {
                while result.count < width { result.append(" ") }
            } else if spec.flags.contains("0") && spec.precision == nil {
                while sign.count + digits.count < width {
                    digits = "0" + digits
                }
                result = sign + digits
            } else {
                while result.count < width { result = " " + result }
            }
        }
        return result
    }

    private static func padNumeric(_ text: String, spec: Spec) -> String {
        guard let width = spec.width else { return text }
        if spec.flags.contains("-") {
            var result = text
            while result.count < width { result.append(" ") }
            return result
        }
        if spec.flags.contains("0") && !text.contains(" ") {
            var sign = ""
            var rest = text
            if rest.hasPrefix("-") || rest.hasPrefix("+") {
                if let first = rest.first { sign = String(first) }
                rest.removeFirst()
            }
            while sign.count + rest.count < width { rest = "0" + rest }
            return sign + rest
        }
        var result = text
        while result.count < width { result = " " + result }
        return result
    }

    private static func pad(_ text: String, width: Int?, leftAlign: Bool) -> String {
        guard let width = width else { return text }
        if text.count >= width { return text }
        if leftAlign {
            var result = text
            while result.count < width { result.append(" ") }
            return result
        }
        var result = text
        while result.count < width { result = " " + result }
        return result
    }
}
