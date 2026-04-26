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
        "xdigit": "0-9A-Fa-f",
    ]

    /// Convert Basic Regular Expression to Extended Regular Expression.
    /// In BRE `+ ? | ( ) { }` are literal; their escaped variants are
    /// special. ERE swaps the two. Also expands `[[:class:]]`.
    static func breToEre(_ pattern: String) -> String {
        var result = ""
        let chars = Array(pattern)
        var i = 0
        var inBracket = false

        while i < chars.count {
            // Standalone POSIX classes outside brackets, e.g. [[:space:]]
            if chars[i] == "[" && !inBracket {
                if i + 2 < chars.count, chars[i + 1] == "[", chars[i + 2] == ":" {
                    if let close = findRange(chars, from: i + 3, end: ":]]") {
                        let className = String(chars[(i + 3)..<close])
                        if let cls = posixClasses[className] {
                            result += "[\(cls)]"
                            i = close + 3
                            continue
                        }
                    }
                }
                if i + 3 < chars.count, chars[i + 1] == "^",
                   chars[i + 2] == "[", chars[i + 3] == ":" {
                    if let close = findRange(chars, from: i + 4, end: ":]]") {
                        let className = String(chars[(i + 4)..<close])
                        if let cls = posixClasses[className] {
                            result += "[^\(cls)]"
                            i = close + 3
                            continue
                        }
                    }
                }
                result += "["
                i += 1
                inBracket = true
                if i < chars.count, chars[i] == "^" { result += "^"; i += 1 }
                if i < chars.count, chars[i] == "]" { result += "\\]"; i += 1 }
                continue
            }

            if inBracket {
                if chars[i] == "]" {
                    result += "]"
                    i += 1
                    inBracket = false
                    continue
                }
                if chars[i] == "[" && i + 1 < chars.count && chars[i + 1] == ":" {
                    if let close = findRange(chars, from: i + 2, end: ":]") {
                        let className = String(chars[(i + 2)..<close])
                        if let cls = posixClasses[className] {
                            result += cls
                            i = close + 2
                            continue
                        }
                    }
                }
                if chars[i] == "\\", i + 1 < chars.count {
                    result.append(chars[i]); result.append(chars[i + 1])
                    i += 2
                    continue
                }
                result.append(chars[i])
                i += 1
                continue
            }

            // Escapes outside brackets
            if chars[i] == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                switch next {
                case "+", "?", "|", "(", ")", "{", "}":
                    result.append(next); i += 2; continue
                case "t": result += "\t"; i += 2; continue
                case "n": result += "\n"; i += 2; continue
                case "r": result += "\r"; i += 2; continue
                default:
                    result.append(chars[i]); result.append(next); i += 2; continue
                }
            }

            // ERE-special chars are literal in BRE
            switch chars[i] {
            case "+", "?", "|", "(", ")", "{", "}":
                result.append("\\"); result.append(chars[i]); i += 1; continue
            case "^":
                let isAnchor = result.isEmpty || result.hasSuffix("(")
                if !isAnchor { result += "\\^"; i += 1; continue }
            case "$":
                let isEnd = i == chars.count - 1
                let beforeGroupClose = i + 2 < chars.count && chars[i + 1] == "\\" && chars[i + 2] == ")"
                if !isEnd && !beforeGroupClose { result += "\\$"; i += 1; continue }
            default: break
            }

            result.append(chars[i])
            i += 1
        }

        return result
    }

    /// Normalize ERE for `NSRegularExpression`: GNU `{,n}` → `{0,n}`.
    static func normalizeForICU(_ pattern: String) -> String {
        var result = ""
        let chars = Array(pattern)
        var i = 0
        var inBracket = false
        while i < chars.count {
            if chars[i] == "[" && !inBracket {
                inBracket = true
                result += "["
                i += 1
                if i < chars.count, chars[i] == "^" { result += "^"; i += 1 }
                if i < chars.count, chars[i] == "]" { result += "]"; i += 1 }
                continue
            }
            if chars[i] == "]" && inBracket {
                inBracket = false; result += "]"; i += 1; continue
            }
            if !inBracket && chars[i] == "{" && i + 1 < chars.count && chars[i + 1] == "," {
                result += "{0,"; i += 2; continue
            }
            result.append(chars[i]); i += 1
        }
        return result
    }

    /// Build an `NSRegularExpression` from a sed pattern, applying
    /// BRE→ERE conversion when `extendedRegex == false`.
    static func compile(_ pattern: String,
                        extendedRegex: Bool,
                        ignoreCase: Bool = false) throws -> NSRegularExpression {
        let p = normalizeForICU(extendedRegex ? pattern : breToEre(pattern))
        var opts: NSRegularExpression.Options = []
        if ignoreCase { opts.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: p, options: opts)
    }

    /// Pretty-print pattern space for the `l` command.
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
        var i = from
        while i + endChars.count <= chars.count {
            var match = true
            for j in 0..<endChars.count {
                if chars[i + j] != endChars[j] { match = false; break }
            }
            if match { return i }
            i += 1
        }
        return nil
    }
}
