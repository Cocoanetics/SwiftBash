import Foundation

/// Regex helpers shared by lexer / executor.
enum SedRegex {

    /// POSIX character classes (e.g., `[:space:]`) → ranges suitable
    /// for an `NSRegularExpression` bracket expression.
    private static let posixClasses: [String: String] = [
        "alnum": "a-zA-Z0-9",
        "alpha": "a-zA-Z",
        "ascii": "\\x00-\\x7F",
        "blank": " \\t",
        "cntrl": "\\x00-\\x1F\\x7F",
        "digit": "0-9",
        "graph": "!-~",
        "lower": "a-z",
        "print": " -~",
        "punct": "!-/:-@\\[-`{-~",
        "space": " \\t\\n\\r\\f\\v",
        "upper": "A-Z",
        "word": "a-zA-Z0-9_",
        "xdigit": "0-9A-Fa-f"
    ]

    // Convert Basic Regular Expression to Extended Regular Expression.
    // In BRE `+ ? | ( ) { }` are literal; their escaped variants are
    // special. ERE swaps the two. Also expands `[[:class:]]`.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func breToEre(_ pattern: String) -> String {
        var result = ""
        let chars = Array(pattern)
        var idx = 0
        var inBracket = false

        while idx < chars.count {
            // Standalone POSIX classes outside brackets, e.g. [[:space:]]
            if chars[idx] == "[" && !inBracket {
                if idx + 2 < chars.count, chars[idx + 1] == "[", chars[idx + 2] == ":" {
                    if let close = findRange(chars, from: idx + 3, end: ":]]") {
                        let className = String(chars[(idx + 3)..<close])
                        if let cls = posixClasses[className] {
                            result += "[\(cls)]"
                            idx = close + 3
                            continue
                        }
                    }
                }
                if idx + 3 < chars.count, chars[idx + 1] == "^",
                   chars[idx + 2] == "[", chars[idx + 3] == ":" {
                    if let close = findRange(chars, from: idx + 4, end: ":]]") {
                        let className = String(chars[(idx + 4)..<close])
                        if let cls = posixClasses[className] {
                            result += "[^\(cls)]"
                            idx = close + 3
                            continue
                        }
                    }
                }
                result += "["
                idx += 1
                inBracket = true
                if idx < chars.count, chars[idx] == "^" { result += "^"; idx += 1 }
                if idx < chars.count, chars[idx] == "]" { result += "\\]"; idx += 1 }
                continue
            }

            if inBracket {
                if chars[idx] == "]" {
                    result += "]"
                    idx += 1
                    inBracket = false
                    continue
                }
                if chars[idx] == "[" && idx + 1 < chars.count && chars[idx + 1] == ":" {
                    if let close = findRange(chars, from: idx + 2, end: ":]") {
                        let className = String(chars[(idx + 2)..<close])
                        if let cls = posixClasses[className] {
                            result += cls
                            idx = close + 2
                            continue
                        }
                    }
                }
                if chars[idx] == "\\", idx + 1 < chars.count {
                    result.append(chars[idx]); result.append(chars[idx + 1])
                    idx += 2
                    continue
                }
                result.append(chars[idx])
                idx += 1
                continue
            }

            // Escapes outside brackets
            if chars[idx] == "\\", idx + 1 < chars.count {
                let next = chars[idx + 1]
                switch next {
                case "+", "?", "|", "(", ")", "{", "}":
                    result.append(next); idx += 2; continue
                case "t": result += "\t"; idx += 2; continue
                case "n": result += "\n"; idx += 2; continue
                case "r": result += "\r"; idx += 2; continue
                default:
                    result.append(chars[idx]); result.append(next); idx += 2; continue
                }
            }

            // ERE-special chars are literal in BRE
            switch chars[idx] {
            case "+", "?", "|", "(", ")", "{", "}":
                result.append("\\"); result.append(chars[idx]); idx += 1; continue
            case "^":
                let isAnchor = result.isEmpty || result.hasSuffix("(")
                if !isAnchor { result += "\\^"; idx += 1; continue }
            case "$":
                let isEnd = idx == chars.count - 1
                let beforeGroupClose = idx + 2 < chars.count && chars[idx + 1] == "\\" && chars[idx + 2] == ")"
                if !isEnd && !beforeGroupClose { result += "\\$"; idx += 1; continue }
            default: break
            }

            result.append(chars[idx])
            idx += 1
        }

        return result
    }

    /// Normalize ERE for `NSRegularExpression`: GNU `{,n}` → `{0,n}`.
    static func normalizeForICU(_ pattern: String) -> String {
        var result = ""
        let chars = Array(pattern)
        var idx = 0
        var inBracket = false
        while idx < chars.count {
            if chars[idx] == "[" && !inBracket {
                inBracket = true
                result += "["
                idx += 1
                if idx < chars.count, chars[idx] == "^" { result += "^"; idx += 1 }
                if idx < chars.count, chars[idx] == "]" { result += "]"; idx += 1 }
                continue
            }
            if chars[idx] == "]" && inBracket {
                inBracket = false; result += "]"; idx += 1; continue
            }
            if !inBracket && chars[idx] == "{" && idx + 1 < chars.count && chars[idx + 1] == "," {
                result += "{0,"; idx += 2; continue
            }
            result.append(chars[idx]); idx += 1
        }
        return result
    }

    /// Build an `NSRegularExpression` from a sed pattern, applying
    /// BRE→ERE conversion when `extendedRegex == false`.
    static func compile(_ pattern: String,
                        extendedRegex: Bool,
                        ignoreCase: Bool = false) throws -> NSRegularExpression {
        let normalized = normalizeForICU(extendedRegex ? pattern : breToEre(pattern))
        var opts: NSRegularExpression.Options = []
        if ignoreCase { opts.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: normalized, options: opts)
    }

    // Pretty-print pattern space for the `l` command.
    // swiftlint:disable:next cyclomatic_complexity
    static func escapeForList(_ input: String) -> String {
        var out = ""
        for scalar in input.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "$\n"
            case "\r": out += "\\r"
            case "\u{07}": out += "\\a"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{0B}": out += "\\v"
            default:
                if scalar.value < 32 || scalar.value >= 127 {
                    out += String(format: "\\%03o", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "$"
    }

    private static func findRange(_ chars: [Character], from: Int, end: String) -> Int? {
        let endChars = Array(end)
        var idx = from
        while idx + endChars.count <= chars.count {
            var match = true
            for offset in 0..<endChars.count where chars[idx + offset] != endChars[offset] {
                match = false
                break
            }
            if match { return idx }
            idx += 1
        }
        return nil
    }
}
