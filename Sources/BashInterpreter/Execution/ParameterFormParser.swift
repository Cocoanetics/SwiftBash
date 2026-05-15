import Foundation

/// Parses the body between `${` and `}` (as captured by ``BashSyntax``'text
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

    // Operator-table dispatch over `${…}` body forms; flattening the
    // top-level switch would scatter the longest-match precedence rule
    // that's the whole point of the function.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func parse(_ body: String) throws -> ParameterForm {
        if body.isEmpty { return .plain("") }
        let chars = Array(body)
        var index = 0

        // Length: `${#name}` — the `#` must be followed by at least one
        // more char, and the rest of the body must be a bare name.
        if chars[0] == "#", chars.count > 1 {
            index = 1
            let name = readName(chars, &index)
            if !name.isEmpty, index == chars.count {
                return .length(name)
            }
            // Otherwise `#` was a special-parameter name; fall through.
            index = 0
        }

        // `!`-prefix forms.
        //   - `${!name[@]}` / `${!name[*]}` → array indices
        //   - `${!name}` → indirect expansion
        if chars[0] == "!", chars.count > 1 {
            index = 1
            let name = readName(chars, &index)
            if !name.isEmpty, index == chars.count {
                if name.hasSuffix("[@]") || name.hasSuffix("[*]") {
                    return .indices(name)
                }
                return .indirect(name)
            }
            index = 0
        }

        let name = readName(chars, &index)
        guard !name.isEmpty else {
            throw BashInterpreterError.parameter("bad parameter body: `\(body)`")
        }
        if index == chars.count { return .plain(name) }

        // Dispatch on the operator. Longest-match first.
        let opChar = chars[index]
        let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil

        switch opChar {
        case "#":
            if next == "#" {
                return .removePrefix(name: name,
                                     pattern: String(chars[(index + 2)...]),
                                     longest: true)
            }
            return .removePrefix(name: name,
                                 pattern: String(chars[(index + 1)...]),
                                 longest: false)

        case "%":
            if next == "%" {
                return .removeSuffix(name: name,
                                     pattern: String(chars[(index + 2)...]),
                                     longest: true)
            }
            return .removeSuffix(name: name,
                                 pattern: String(chars[(index + 1)...]),
                                 longest: false)

        case "/":
            var all = false
            var anchor = ParameterForm.ReplaceAnchor.any
            var start = index + 1
            if next == "/" {
                all = true; start += 1
            } else if next == "#" {
                anchor = .start; start += 1
            } else if next == "%" {
                anchor = .end; start += 1
            }
            let (pattern, replacement) = splitOnUnescapedSlash(chars, from: start)
            return .replace(name: name,
                            pattern: pattern,
                            replacement: replacement,
                            all: all,
                            anchor: anchor)

        case ":":
            return try parseColonForm(name: name, chars: chars,
                                      index: index, next: next, body: body)

        case "-":
            return .defaultValue(name: name, checkEmpty: false,
                                 value: String(chars[(index + 1)...]))
        case "=":
            return .assignDefault(name: name, checkEmpty: false,
                                  value: String(chars[(index + 1)...]))
        case "?":
            return .errorIfUnset(name: name, checkEmpty: false,
                                 message: String(chars[(index + 1)...]))
        case "+":
            return .alternative(name: name, checkEmpty: false,
                                value: String(chars[(index + 1)...]))

        case "^":
            // `${name^}` first matching char → upper.
            // `${name^^}` every matching char → upper.
            // Optional pattern follows: `${name^^[abc]}`.
            let all = (next == "^")
            let patStart = all ? index + 2 : index + 1
            return .caseConvert(name: name, toUpper: true, all: all,
                                pattern: String(chars[patStart...]))

        case ",":
            let all = (next == ",")
            let patStart = all ? index + 2 : index + 1
            return .caseConvert(name: name, toUpper: false, all: all,
                                pattern: String(chars[patStart...]))

        default:
            // Unrecognised operator — fall back to plain lookup so the
            // interpreter degrades gracefully rather than throwing on
            // exotic bodies it doesn't yet understand.
            return .plain(name)
        }
    }

    /// Dispatch the colon-prefixed forms: `:-`, `:=`, `:?`, `:+`, and
    /// the substring `:offset[:length]`.
    private static func parseColonForm(name: String,
                                       chars: [Character],
                                       index: Int,
                                       next: Character?,
                                       body: String) throws -> ParameterForm {
        guard let nextChar = next else {
            throw BashInterpreterError.parameter("bad parameter body: `\(body)`")
        }
        switch nextChar {
        case "-":
            return .defaultValue(name: name, checkEmpty: true,
                                 value: String(chars[(index + 2)...]))
        case "=":
            return .assignDefault(name: name, checkEmpty: true,
                                  value: String(chars[(index + 2)...]))
        case "?":
            return .errorIfUnset(name: name, checkEmpty: true,
                                 message: String(chars[(index + 2)...]))
        case "+":
            return .alternative(name: name, checkEmpty: true,
                                value: String(chars[(index + 2)...]))
        default:
            return try parseSubstring(name: name, chars: chars,
                                      from: index + 1)
        }
    }
}
