import Foundation

/// Parses the body between `${` and `}` (as captured by ``BashSyntax``'s
/// `.parameter` node) into a ``ParameterForm``.
///
/// Grammar (highest-precedence first):
///
/// ```
/// body ::=                              →  .plain("")
///        | '#' name                     →  .length(name)
///        | name                         →  .plain(name)
///        | name '##' pattern            →  .removePrefix(longest: true)
///        | name '#'  pattern            →  .removePrefix(longest: false)
///        | name '%%' pattern            →  .removeSuffix(longest: true)
///        | name '%'  pattern            →  .removeSuffix(longest: false)
///        | name '/#' pat '/' repl       →  .replace(anchor: .start)
///        | name '/%' pat '/' repl       →  .replace(anchor: .end)
///        | name '//' pat '/' repl       →  .replace(all: true)
///        | name '/'  pat '/' repl       →  .replace(all: false, anchor: .any)
///        | name ':-' word               →  .defaultValue(checkEmpty: true)
///        | name  '-' word               →  .defaultValue(checkEmpty: false)
///        | name ':=' word               →  .assignDefault(checkEmpty: true)
///        | name  '=' word               →  .assignDefault(checkEmpty: false)
///        | name ':?' word               →  .errorIfUnset(checkEmpty: true)
///        | name  '?' word               →  .errorIfUnset(checkEmpty: false)
///        | name ':+' word               →  .alternative(checkEmpty: true)
///        | name  '+' word               →  .alternative(checkEmpty: false)
///        | name ':' offset [ ':' len ]  →  .substring
/// ```
///
/// `name` is either a bare identifier (`[a-zA-Z_][a-zA-Z0-9_]*`), a digit
/// (positional parameter), or one of the single-character special
/// parameters `? # $ ! * @ - _`.
enum ParameterFormParser {

    static func parse(_ body: String) throws -> ParameterForm {
        if body.isEmpty { return .plain("") }
        let chars = Array(body)
        var i = 0

        // Length: `${#name}` — the `#` must be followed by at least one
        // more char, and the rest of the body must be a bare name.
        if chars[0] == "#", chars.count > 1 {
            i = 1
            let name = readName(chars, &i)
            if !name.isEmpty, i == chars.count {
                return .length(name)
            }
            // Otherwise `#` was a special-parameter name; fall through.
            i = 0
        }

        let name = readName(chars, &i)
        guard !name.isEmpty else {
            throw BashInterpreterError.parameter("bad parameter body: `\(body)`")
        }
        if i == chars.count { return .plain(name) }

        // Dispatch on the operator. Longest-match first.
        let op = chars[i]
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

        switch op {
        case "#":
            if next == "#" {
                return .removePrefix(name: name,
                                     pattern: String(chars[(i + 2)...]),
                                     longest: true)
            }
            return .removePrefix(name: name,
                                 pattern: String(chars[(i + 1)...]),
                                 longest: false)

        case "%":
            if next == "%" {
                return .removeSuffix(name: name,
                                     pattern: String(chars[(i + 2)...]),
                                     longest: true)
            }
            return .removeSuffix(name: name,
                                 pattern: String(chars[(i + 1)...]),
                                 longest: false)

        case "/":
            var all = false
            var anchor = ParameterForm.ReplaceAnchor.any
            var start = i + 1
            if next == "/" { all = true; start += 1 }
            else if next == "#" { anchor = .start; start += 1 }
            else if next == "%" { anchor = .end; start += 1 }
            let (pattern, replacement) = splitOnUnescapedSlash(chars, from: start)
            return .replace(name: name,
                            pattern: pattern,
                            replacement: replacement,
                            all: all,
                            anchor: anchor)

        case ":":
            if let n = next {
                switch n {
                case "-":
                    return .defaultValue(name: name, checkEmpty: true,
                                         value: String(chars[(i + 2)...]))
                case "=":
                    return .assignDefault(name: name, checkEmpty: true,
                                          value: String(chars[(i + 2)...]))
                case "?":
                    return .errorIfUnset(name: name, checkEmpty: true,
                                         message: String(chars[(i + 2)...]))
                case "+":
                    return .alternative(name: name, checkEmpty: true,
                                        value: String(chars[(i + 2)...]))
                default:
                    return try parseSubstring(name: name, chars: chars,
                                              from: i + 1)
                }
            }
            throw BashInterpreterError.parameter("bad parameter body: `\(body)`")

        case "-":
            return .defaultValue(name: name, checkEmpty: false,
                                 value: String(chars[(i + 1)...]))
        case "=":
            return .assignDefault(name: name, checkEmpty: false,
                                  value: String(chars[(i + 1)...]))
        case "?":
            return .errorIfUnset(name: name, checkEmpty: false,
                                 message: String(chars[(i + 1)...]))
        case "+":
            return .alternative(name: name, checkEmpty: false,
                                value: String(chars[(i + 1)...]))

        default:
            // Unrecognised operator — fall back to plain lookup so the
            // interpreter degrades gracefully rather than throwing on
            // exotic bodies it doesn't yet understand.
            return .plain(name)
        }
    }

    // MARK: Helpers

    /// Read a parameter name at `chars[i]` and advance `i`. Accepts
    /// single-character special parameters, a digit run (positional),
    /// or a regular identifier.
    private static func readName(_ chars: [Character], _ i: inout Int) -> String {
        guard i < chars.count else { return "" }
        let first = chars[i]

        // Single-character special parameters.
        if "?$#!*@".contains(first) {
            i += 1
            return String(first)
        }

        // Digits (positional parameters). Treated as a single digit by
        // bash but we accept the full run for forward-compatibility.
        if first.isNumber {
            var s = ""
            while i < chars.count, chars[i].isNumber {
                s.append(chars[i])
                i += 1
            }
            return s
        }

        // Regular identifier.
        if first.isLetter || first == "_" {
            var s = ""
            while i < chars.count,
                  chars[i].isLetter || chars[i].isNumber || chars[i] == "_"
            {
                s.append(chars[i])
                i += 1
            }
            return s
        }

        return ""
    }

    /// Parse a substring form: `offset` or `offset:length`, where each
    /// number may be negative. Matches bash: negative offsets index from
    /// the end of the string; negative length means "up to N from the end".
    private static func parseSubstring(name: String,
                                       chars: [Character],
                                       from: Int) throws -> ParameterForm {
        var i = from
        guard let offset = readIntLiteral(chars, &i) else {
            throw BashInterpreterError.parameter("malformed substring: `\(String(chars[from...]))`")
        }
        if i == chars.count {
            return .substring(name: name, offset: offset, length: nil)
        }
        guard chars[i] == ":" else {
            throw BashInterpreterError.parameter("expected `:` in substring form")
        }
        i += 1
        guard let length = readIntLiteral(chars, &i) else {
            throw BashInterpreterError.parameter("malformed substring: `\(String(chars[from...]))`")
        }
        return .substring(name: name, offset: offset, length: length)
    }

    private static func readIntLiteral(_ chars: [Character],
                                       _ i: inout Int) -> Int? {
        // Skip optional leading spaces (bash allows `${var: -1}` which
        // is NOT the same as `${var:-1}` — the leading space disambiguates).
        while i < chars.count, chars[i] == " " { i += 1 }
        var j = i
        if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
        while j < chars.count, chars[j].isNumber { j += 1 }
        guard j > i else { return nil }
        // If we only consumed a sign, fail.
        let s = String(chars[i..<j])
        guard let n = Int(s) else { return nil }
        i = j
        return n
    }

    /// Split the pattern / replacement pair in `${name/pat/rep}` on the
    /// first unescaped `/`. If there is no separator, the whole tail is
    /// the pattern and the replacement is empty (matching bash).
    private static func splitOnUnescapedSlash(_ chars: [Character],
                                              from start: Int)
        -> (pattern: String, replacement: String)
    {
        var pattern = ""
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                pattern.append(c)
                pattern.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "/" { return (pattern, String(chars[(i + 1)...])) }
            pattern.append(c)
            i += 1
        }
        return (pattern, "")
    }
}
