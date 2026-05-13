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

        // `!`-prefix forms.
        //   - `${!name[@]}` / `${!name[*]}` → array indices
        //   - `${!name}` → indirect expansion
        if chars[0] == "!", chars.count > 1 {
            i = 1
            let name = readName(chars, &i)
            if !name.isEmpty, i == chars.count {
                if name.hasSuffix("[@]") || name.hasSuffix("[*]") {
                    return .indices(name)
                }
                return .indirect(name)
            }
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

        case "^":
            // `${name^}` first matching char → upper.
            // `${name^^}` every matching char → upper.
            // Optional pattern follows: `${name^^[abc]}`.
            let all = (next == "^")
            let patStart = all ? i + 2 : i + 1
            return .caseConvert(name: name, toUpper: true, all: all,
                                pattern: String(chars[patStart...]))

        case ",":
            let all = (next == ",")
            let patStart = all ? i + 2 : i + 1
            return .caseConvert(name: name, toUpper: false, all: all,
                                pattern: String(chars[patStart...]))

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

        // Regular identifier — possibly with `[subscript]` suffix.
        if first.isLetter || first == "_" {
            var s = ""
            while i < chars.count,
                  chars[i].isLetter || chars[i].isNumber || chars[i] == "_"
            {
                s.append(chars[i])
                i += 1
            }
            // Optional `[subscript]` for indexed arrays. The
            // subscript text is preserved as part of the name so the
            // interpreter's `lookup` can split it back out.
            if i < chars.count, chars[i] == "[" {
                let saved = i
                i += 1
                var sub = ""
                while i < chars.count, chars[i] != "]" {
                    sub.append(chars[i])
                    i += 1
                }
                if i < chars.count, chars[i] == "]" {
                    i += 1
                    s += "[\(sub)]"
                } else {
                    i = saved
                }
            }
            return s
        }

        return ""
    }

    /// Parse a substring form: `offset` or `offset:length`. Bash
    /// evaluates both as arithmetic expressions at expansion time
    /// — `${text:$i:1}`, `${arr:i+2:k}`, `${s: -1}`,
    /// `${var:i?a:b:1}`, `${var:$(cmd):1}`, `${var:${other}:1}` all
    /// work. We capture the raw text up to the next *outermost* `:`
    /// (offset) and up to end-of-body (length); the evaluator hands
    /// the captured strings to `evaluateArithmetic` at use time.
    private static func parseSubstring(name: String,
                                       chars: [Character],
                                       from: Int) throws -> ParameterForm {
        var i = from
        let offset = readSubstringField(chars, &i, terminatesOnColon: true)
        if offset.trimmingCharacters(in: .whitespaces).isEmpty {
            throw BashInterpreterError.parameter(
                "malformed substring: `\(String(chars[from...]))`")
        }
        if i == chars.count {
            return .substring(name: name, offset: offset, length: nil)
        }
        // Skip the `:` separator.
        i += 1
        let length = readSubstringField(chars, &i, terminatesOnColon: false)
        if length.trimmingCharacters(in: .whitespaces).isEmpty {
            // `${var:1:}` — bash flags an empty length as a syntax
            // error, not "no length supplied". Match that.
            throw BashInterpreterError.parameter(
                "malformed substring: `\(String(chars[from...]))`")
        }
        return .substring(name: name, offset: offset, length: length)
    }

    /// Capture one arithmetic-expression field — `offset` or
    /// `length` — from the substring body. Walks character by
    /// character maintaining a nesting stack so the field
    /// separator `:` is only recognised at the outermost level,
    /// matching bash's own tokenizer.
    ///
    /// Tracked nestings:
    /// - `'…'`         single-quote — `:` inside is literal
    /// - `"…"`         double-quote — `:` inside is literal; `$…`
    ///                 expansions inside still open sub-states
    /// - `` `…` ``     backtick command substitution
    /// - `$( … )`      `$(`-style command substitution
    /// - `$(( … ))`    arithmetic expansion (nests as `$(`+`(`)
    /// - `${ … }`      parameter expansion
    /// - `( … )`       parenthesised arithmetic / grouping
    /// - `\X`          backslash escape: takes the next char literally
    ///                 (only outside single quotes)
    /// - `? … :`       arithmetic ternary at the outermost level —
    ///                 the `:` belongs to the ternary, not the field
    ///                 separator
    ///
    /// `terminatesOnColon == false` reads through end-of-input,
    /// used for the trailing length field.
    private static func readSubstringField(
        _ chars: [Character],
        _ i: inout Int,
        terminatesOnColon: Bool
    ) -> String {
        var out = ""
        var stack: [NestState] = []
        var ternaryDepth = 0  // only meaningful when `stack` is empty

        while i < chars.count {
            let c = chars[i]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
            let nextNext: Character? = (i + 2 < chars.count) ? chars[i + 2] : nil
            let inside = stack.last

            // Single quote: nothing except `'` ends it. Even `\` is
            // literal here.
            if inside == .singleQuote {
                if c == "'" { stack.removeLast() }
                out.append(c); i += 1; continue
            }

            // Backslash escape — anywhere except inside single
            // quotes. Consumes the pair without inspecting the
            // following char so `\:` or `\$` don't change state.
            if c == "\\", let n = next {
                out.append(c); out.append(n)
                i += 2; continue
            }

            // Backtick: nothing except a literal `` ` `` ends it
            // (we already stripped backslash-escaped backticks above).
            if inside == .backtick {
                if c == "`" { stack.removeLast() }
                out.append(c); i += 1; continue
            }

            // Field terminator. Only at the *outermost* level —
            // inside any nesting or unresolved ternary, the colon
            // belongs to that sub-form.
            if stack.isEmpty,
               terminatesOnColon,
               c == ":",
               ternaryDepth == 0
            {
                break
            }

            // State transitions.
            switch c {
            case "'":
                // Inside double quotes single quotes don't open a
                // new region (bash treats them as literal there).
                if inside != .doubleQuote { stack.append(.singleQuote) }
            case "\"":
                if inside == .doubleQuote { stack.removeLast() }
                else { stack.append(.doubleQuote) }
            case "`":
                stack.append(.backtick)
            case "$":
                if next == "{" {
                    stack.append(.dollarBrace)
                    out.append(c); out.append("{")
                    i += 2; continue
                }
                if next == "(" {
                    // `$((` opens arithmetic — treat as `$(` + `(`
                    // so the matching `))` closes by popping the
                    // inner paren then the dollarParen.
                    if nextNext == "(" {
                        stack.append(.dollarParen)
                        stack.append(.paren)
                        out.append(c); out.append("("); out.append("(")
                        i += 3; continue
                    }
                    stack.append(.dollarParen)
                    out.append(c); out.append("(")
                    i += 2; continue
                }
            case "(":
                stack.append(.paren)
            case ")":
                if inside == .paren { stack.removeLast() }
                else if inside == .dollarParen { stack.removeLast() }
            case "{":
                // A bare `{` that isn't part of `${`. Push so a
                // stray `:` inside doesn't split.
                stack.append(.brace)
            case "}":
                if inside == .brace || inside == .dollarBrace {
                    stack.removeLast()
                }
                // Otherwise: stray `}` — leave it in the captured
                // text and let the arithmetic evaluator complain.
            case "?":
                if stack.isEmpty { ternaryDepth += 1 }
            case ":":
                // We already checked the terminator case at the top
                // of the loop. Reaching here means we ARE inside a
                // ternary at outer level — bind this `:` to it.
                if stack.isEmpty, ternaryDepth > 0 { ternaryDepth -= 1 }
            default:
                break
            }

            out.append(c)
            i += 1
        }
        return out
    }

    /// One frame of `readSubstringField`'s nesting stack.
    private enum NestState {
        case singleQuote
        case doubleQuote
        case backtick
        case paren
        case brace
        case dollarParen
        case dollarBrace
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
