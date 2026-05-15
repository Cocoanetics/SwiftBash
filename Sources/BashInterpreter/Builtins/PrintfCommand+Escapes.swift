import Foundation

extension PrintfCommand {

    // Expand the backslash escape at `chars[start]` (must be `\\`).
    // Returns the substituted text and how many input chars were
    // consumed (always at least 1).
    //
    // Backslash-escape dispatch table; one case per supported escape.
    // swiftlint:disable:next cyclomatic_complexity
    func expandBackslash(_ chars: [Character], from start: Int)
        -> (String, Int) {
        guard start + 1 < chars.count else { return ("\\", 1) }
        let char = chars[start + 1]
        switch char {
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
            var value = 0
            var len = 2
            for _ in 0..<3 {
                let pos = start + len
                guard pos < chars.count,
                      let digit = chars[pos].hexDigitValue, digit < 8 else { break }
                value = value * 8 + digit
                len += 1
            }
            return (scalar(value), len)
        case "x":
            // `\xHH` — 1 or 2 hex digits.
            var value = 0
            var len = 2
            for _ in 0..<2 {
                let pos = start + len
                guard pos < chars.count,
                      let digit = chars[pos].hexDigitValue else { break }
                value = value * 16 + digit
                len += 1
            }
            if len == 2 { return ("\\x", 2) }
            return (scalar(value), len)
        case "u":
            return readUnicode(chars, after: start + 2, digits: 4, escapeLen: 2)
        case "U":
            return readUnicode(chars, after: start + 2, digits: 8, escapeLen: 2)
        default:
            return ("\\\(char)", 2)
        }
    }

    func readUnicode(_ chars: [Character], after start: Int,
                     digits: Int, escapeLen: Int) -> (String, Int) {
        var value = 0
        var len = escapeLen
        for _ in 0..<digits {
            let pos = start + (len - escapeLen)
            guard pos < chars.count,
                  let digit = chars[pos].hexDigitValue else { break }
            value = value * 16 + digit
            len += 1
        }
        if len == escapeLen {
            return ("\\\(chars[start - 1])", escapeLen)
        }
        return (scalar(value), len)
    }

    func scalar(_ value: Int) -> String {
        UnicodeScalar(value).map { String($0) } ?? ""
    }

    /// Shell-quote `str` so it reads back as the same word. Single-quote
    /// when possible; embedded `'` becomes `'\''`. Empty stays as `''`.
    func shellQuote(_ str: String) -> String {
        if str.isEmpty { return "''" }
        // Already-safe? POSIX portable filename character set + a few extras.
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if str.allSatisfy({ safe.contains($0) }) { return str }
        var quoted = "'"
        for char in str {
            if char == "'" { quoted += "'\\''" } else { quoted.append(char) }
        }
        quoted += "'"
        return quoted
    }

    func pad(_ str: String, width: String,
             leftAlign: Bool, zero: Bool) -> String {
        guard let widthVal = Int(width), widthVal > str.count else { return str }
        let padCh: Character = zero ? "0" : " "
        let padding = String(repeating: padCh, count: widthVal - str.count)
        return leftAlign ? str + padding : padding + str
    }

    func parseIntArg(_ str: String) -> Int {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
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
}
