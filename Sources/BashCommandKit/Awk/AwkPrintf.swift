import Foundation

/// AWK printf / sprintf formatting. Supports the POSIX format
/// specifiers (`% [flags] [width] [.precision] [length] conv`),
/// positional arguments (`%n$`), `*` for width / precision drawn
/// from arg list, and the standard escape sequences in the format
/// string itself.
enum AwkPrintf {

    private static let maxWidth = 10_000

    static func format(_ fmt: String, values: [AwkValue]) -> String {
        let chars = Array(fmt)
        var out = ""
        var idx = 0          // sequential value index
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%" && i + 1 < chars.count {
                let parsed = parseSpec(chars, start: i + 1, valueIdx: idx, values: values)
                let spec = parsed.spec
                let valIdx = spec.positional ?? parsed.idxAfter
                let v = valIdx < values.count ? values[valIdx] : AwkValue.empty
                out += renderSpec(spec, value: v)
                idx = parsed.idxAfter
                if spec.positional == nil && spec.conv != "%" {
                    idx += 1
                }
                i = parsed.endPos
            } else if c == "\\" && i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": out += "\n"; i += 2
                case "t": out += "\t"; i += 2
                case "r": out += "\r"; i += 2
                case "\\": out += "\\"; i += 2
                case "/": out += "/"; i += 2
                case "\"": out += "\""; i += 2
                case "a": out += "\u{07}"; i += 2
                case "b": out += "\u{08}"; i += 2
                case "f": out += "\u{0C}"; i += 2
                case "v": out += "\u{0B}"; i += 2
                default: out.append(chars[i + 1]); i += 2
                }
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }

    private struct Spec {
        var flags: String = ""
        var width: Int? = nil
        var precision: Int? = nil
        var conv: Character = "s"
        var positional: Int? = nil
    }

    private struct ParseResult {
        let spec: Spec
        let endPos: Int      // position just past the conversion char
        let idxAfter: Int    // updated value index (for `*` consumption)
    }

    private static func parseSpec(_ chars: [Character], start: Int,
                                  valueIdx: Int, values: [AwkValue]) -> ParseResult {
        var spec = Spec()
        var i = start
        var idx = valueIdx

        // Positional arg: %n$
        let posStart = i
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
        if i > posStart && i < chars.count && chars[i] == "$" {
            spec.positional = (Int(String(chars[posStart..<i])) ?? 1) - 1
            i += 1
        } else {
            i = posStart
        }

        while i < chars.count, "-+ #0".contains(chars[i]) {
            spec.flags.append(chars[i]); i += 1
        }

        if i < chars.count && chars[i] == "*" {
            i += 1
            if idx < values.count {
                let w = Int(values[idx].asNumber)
                idx += 1
                if w < 0 { spec.flags.append("-"); spec.width = min(-w, maxWidth) }
                else { spec.width = min(w, maxWidth) }
            }
        } else {
            var w = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                w.append(chars[i]); i += 1
            }
            if !w.isEmpty {
                spec.width = min(Int(w) ?? 0, maxWidth)
            }
        }

        if i < chars.count && chars[i] == "." {
            i += 1
            if i < chars.count && chars[i] == "*" {
                i += 1
                if idx < values.count {
                    spec.precision = min(max(0, Int(values[idx].asNumber)), maxWidth)
                    idx += 1
                }
            } else {
                var p = ""
                while i < chars.count, chars[i].isASCII, chars[i].isNumber {
                    p.append(chars[i]); i += 1
                }
                spec.precision = min(Int(p) ?? 0, maxWidth)
            }
        }

        // Skip length modifiers (l/ll/h/hh/z/j) — ignored.
        while i < chars.count, "lhzj".contains(chars[i]) { i += 1 }

        if i < chars.count {
            spec.conv = chars[i]
            i += 1
        }
        return ParseResult(spec: spec, endPos: i, idxAfter: idx)
    }

    private static func renderSpec(_ spec: Spec, value: AwkValue) -> String {
        switch spec.conv {
        case "%":
            return "%"
        case "s":
            var s = value.asString
            if let p = spec.precision { s = String(s.prefix(p)) }
            return pad(s, width: spec.width, leftAlign: spec.flags.contains("-"))
        case "c":
            if case .number(let n) = value, let u = Unicode.Scalar(UInt32(Int(n) & 0xFF)) {
                return pad(String(Character(u)),
                           width: spec.width, leftAlign: spec.flags.contains("-"))
            }
            let s = value.asString
            return pad(String(s.first.map { String($0) } ?? ""),
                       width: spec.width, leftAlign: spec.flags.contains("-"))
        case "d", "i":
            let n = Int64(value.asNumber.rounded(.towardZero))
            return formatInteger(n, base: 10, upper: false, spec: spec)
        case "o":
            let n = Int64(value.asNumber.rounded(.towardZero))
            return formatInteger(n, base: 8, upper: false, spec: spec)
        case "x":
            let n = Int64(value.asNumber.rounded(.towardZero))
            return formatInteger(n, base: 16, upper: false, spec: spec)
        case "X":
            let n = Int64(value.asNumber.rounded(.towardZero))
            return formatInteger(n, base: 16, upper: true, spec: spec)
        case "u":
            let n = UInt64(bitPattern: Int64(value.asNumber.rounded(.towardZero)))
            return formatInteger(Int64(bitPattern: n), base: 10, upper: false, spec: spec)
        case "f", "F":
            let n = value.asNumber
            let prec = spec.precision ?? 6
            let s = String(format: "%.\(prec)f", n)
            return padNumeric(s, spec: spec)
        case "e", "E":
            let n = value.asNumber
            let prec = spec.precision ?? 6
            var s = String(format: "%.\(prec)\(spec.conv)", n)
            if spec.conv == "E" { s = s.uppercased() }
            return padNumeric(s, spec: spec)
        case "g", "G":
            let n = value.asNumber
            let prec = spec.precision ?? 6
            var s = String(format: "%.\(prec)\(spec.conv)", n)
            return padNumeric(s, spec: spec)
        default:
            return "%" + String(spec.conv)
        }
    }

    private static func formatInteger(_ n: Int64, base: Int, upper: Bool, spec: Spec) -> String {
        var digits: String
        let absVal = n < 0 ? UInt64(bitPattern: Int64(-n)) : UInt64(n)
        switch base {
        case 8: digits = String(absVal, radix: 8)
        case 16: digits = String(absVal, radix: 16, uppercase: upper)
        default: digits = String(absVal, radix: 10)
        }
        if let p = spec.precision {
            while digits.count < p { digits = "0" + digits }
        }
        var sign = ""
        if n < 0 { sign = "-" }
        else if spec.flags.contains("+") { sign = "+" }
        else if spec.flags.contains(" ") { sign = " " }
        var result = sign + digits
        if let w = spec.width {
            if spec.flags.contains("-") {
                while result.count < w { result.append(" ") }
            } else if spec.flags.contains("0") && spec.precision == nil {
                while sign.count + digits.count < w {
                    digits = "0" + digits
                }
                result = sign + digits
            } else {
                while result.count < w { result = " " + result }
            }
        }
        return result
    }

    private static func padNumeric(_ s: String, spec: Spec) -> String {
        guard let w = spec.width else { return s }
        if spec.flags.contains("-") {
            var r = s; while r.count < w { r.append(" ") }; return r
        }
        if spec.flags.contains("0") && !s.contains(" ") {
            var sign = ""
            var rest = s
            if rest.hasPrefix("-") || rest.hasPrefix("+") {
                sign = String(rest.first!); rest.removeFirst()
            }
            while sign.count + rest.count < w { rest = "0" + rest }
            return sign + rest
        }
        var r = s; while r.count < w { r = " " + r }; return r
    }

    private static func pad(_ s: String, width: Int?, leftAlign: Bool) -> String {
        guard let w = width else { return s }
        if s.count >= w { return s }
        if leftAlign {
            var r = s; while r.count < w { r.append(" ") }; return r
        }
        var r = s; while r.count < w { r = " " + r }; return r
    }
}
