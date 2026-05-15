import Foundation

extension Shell {

    // Decode bash's `$'…'` ANSI-C quoting body into the bytes it
    // represents. Mirrors what `bash` calls "ANSI-C escape
    // expansion": the escapes specified in the GNU bash reference,
    // including the octal / hex / unicode / control-char forms.
    // Unrecognised escape sequences are preserved verbatim (a
    // backslash + the following character), matching real bash.
    // Large switch dispatch over bash's escape table; per-case helpers
    // would scatter the table and harm readability.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func decodeAnsiCEscapes(_ source: String) -> String {
        var out = ""
        let chars = Array(source)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            guard char == "\\", index + 1 < chars.count else {
                out.append(char)
                index += 1
                continue
            }
            let next = chars[index + 1]
            switch next {
            case "a":  out.append("\u{07}"); index += 2
            case "b":  out.append("\u{08}"); index += 2
            case "e", "E": out.append("\u{1B}"); index += 2
            case "f":  out.append("\u{0C}"); index += 2
            case "n":  out.append("\n");     index += 2
            case "r":  out.append("\r");     index += 2
            case "t":  out.append("\t");     index += 2
            case "v":  out.append("\u{0B}"); index += 2
            case "\\": out.append("\\");     index += 2
            case "'":  out.append("'");      index += 2
            case "\"": out.append("\"");     index += 2
            case "?":  out.append("?");      index += 2
            case "0"..."7":
                // Octal escape: up to three digits.
                var digits = ""
                var inner = index + 1
                while inner < chars.count, digits.count < 3,
                      ("0"..."7").contains(chars[inner]) {
                    digits.append(chars[inner]); inner += 1
                }
                if let value = UInt32(digits, radix: 8),
                   let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                }
                index = inner
            case "x":
                // `\xHH` — up to two hex digits.
                var digits = ""
                var inner = index + 2
                while inner < chars.count, digits.count < 2,
                      chars[inner].isHexDigit {
                    digits.append(chars[inner]); inner += 1
                }
                if !digits.isEmpty,
                   let value = UInt32(digits, radix: 16),
                   let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    index = inner
                } else {
                    // Bash preserves `\x` literally when no hex
                    // digits follow.
                    out.append("\\"); out.append("x")
                    index += 2
                }
            case "u":
                // `\uHHHH` — up to four hex digits.
                var digits = ""
                var inner = index + 2
                while inner < chars.count, digits.count < 4,
                      chars[inner].isHexDigit {
                    digits.append(chars[inner]); inner += 1
                }
                if !digits.isEmpty,
                   let value = UInt32(digits, radix: 16),
                   let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    index = inner
                } else {
                    out.append("\\"); out.append("u")
                    index += 2
                }
            case "U":
                // `\UHHHHHHHH` — up to eight hex digits.
                var digits = ""
                var inner = index + 2
                while inner < chars.count, digits.count < 8,
                      chars[inner].isHexDigit {
                    digits.append(chars[inner]); inner += 1
                }
                if !digits.isEmpty,
                   let value = UInt32(digits, radix: 16),
                   let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    index = inner
                } else {
                    out.append("\\"); out.append("U")
                    index += 2
                }
            case "c":
                // `\cX` — control character (X with bit 6 toggled).
                if index + 2 < chars.count,
                   let ascii = chars[index + 2].asciiValue {
                    out.append(Character(Unicode.Scalar(ascii & 0x1F)))
                    index += 3
                } else {
                    out.append("\\"); out.append("c")
                    index += 2
                }
            default:
                // Unrecognised — preserve `\X` verbatim.
                out.append("\\"); out.append(next)
                index += 2
            }
        }
        return out
    }
}
