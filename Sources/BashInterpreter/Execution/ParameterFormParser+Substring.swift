import Foundation

extension ParameterFormParser {

    /// Parse a substring form: `offset` or `offset:length`. Bash
    /// evaluates both as arithmetic expressions at expansion time
    /// — `${text:$index:1}`, `${arr:index+2:k}`, `${text: -1}`,
    /// `${var:index?a:b:1}`, `${var:$(cmd):1}`, `${var:${other}:1}` all
    /// work. We capture the raw text up to the next *outermost* `:`
    /// (offset) and up to end-of-body (length); the evaluator hands
    /// the captured strings to `evaluateArithmetic` at use time.
    static func parseSubstring(name: String,
                               chars: [Character],
                               from: Int) throws -> ParameterForm {
        var index = from
        let offset = readSubstringField(chars, &index, terminatesOnColon: true)
        if offset.trimmingCharacters(in: .whitespaces).isEmpty {
            throw BashInterpreterError.parameter(
                "malformed substring: `\(String(chars[from...]))`")
        }
        if index == chars.count {
            return .substring(name: name, offset: offset, length: nil)
        }
        // Skip the `:` separator.
        index += 1
        let length = readSubstringField(chars, &index, terminatesOnColon: false)
        if length.trimmingCharacters(in: .whitespaces).isEmpty {
            // `${var:1:}` — bash flags an empty length as a syntax
            // error, not "no length supplied". Match that.
            throw BashInterpreterError.parameter(
                "malformed substring: `\(String(chars[from...]))`")
        }
        return .substring(name: name, offset: offset, length: length)
    }

    // Capture one arithmetic-expression field — `offset` or
    // `length` — from the substring body. Walks character by
    // character maintaining a nesting stack so the field
    // separator `:` is only recognised at the outermost level,
    // matching bash'text own tokenizer.
    //
    // Tracked nestings:
    // - `'…'`         single-quote — `:` inside is literal
    // - `"…"`         double-quote — `:` inside is literal; `$…`
    //                 expansions inside still open sub-states
    // - `` `…` ``     backtick command substitution
    // - `$( … )`      `$(`-style command substitution
    // - `$(( … ))`    arithmetic expansion (nests as `$(`+`(`)
    // - `${ … }`      parameter expansion
    // - `( … )`       parenthesised arithmetic / grouping
    // - `\X`          backslash escape: takes the next char literally
    //                 (only outside single quotes)
    // - `? … :`       arithmetic ternary at the outermost level —
    //                 the `:` belongs to the ternary, not the field
    //                 separator
    //
    // `terminatesOnColon == false` reads through end-of-input,
    // used for the trailing length field.
    //
    // State machine that recognises ~10 distinct nesting contexts; the
    // outer cyclomatic count is a function of the grammar, not of any
    // split-able structure.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func readSubstringField(
        _ chars: [Character],
        _ index: inout Int,
        terminatesOnColon: Bool
    ) -> String {
        var out = ""
        var stack: [NestState] = []
        var ternaryDepth = 0  // only meaningful when `stack` is empty

        while index < chars.count {
            let char = chars[index]
            let next: Character? = (index + 1 < chars.count) ? chars[index + 1] : nil
            let nextNext: Character? = (index + 2 < chars.count) ? chars[index + 2] : nil
            let inside = stack.last

            // Single quote: nothing except `'` ends it. Even `\` is
            // literal here.
            if inside == .singleQuote {
                if char == "'" { stack.removeLast() }
                out.append(char); index += 1; continue
            }

            // Backslash escape — anywhere except inside single
            // quotes. Consumes the pair without inspecting the
            // following char so `\:` or `\$` don't change state.
            if char == "\\", let nextChar = next {
                out.append(char); out.append(nextChar)
                index += 2; continue
            }

            // Backtick: nothing except a literal `` ` `` ends it
            // (we already stripped backslash-escaped backticks above).
            if inside == .backtick {
                if char == "`" { stack.removeLast() }
                out.append(char); index += 1; continue
            }

            // Field terminator. Only at the *outermost* level —
            // inside any nesting or unresolved ternary, the colon
            // belongs to that sub-form.
            if stack.isEmpty,
               terminatesOnColon,
               char == ":",
               ternaryDepth == 0 {
                break
            }

            // State transitions.
            switch char {
            case "'":
                // Inside double quotes single quotes don't open a
                // new region (bash treats them as literal there).
                if inside != .doubleQuote { stack.append(.singleQuote) }
            case "\"":
                if inside == .doubleQuote { stack.removeLast() } else { stack.append(.doubleQuote) }
            case "`":
                stack.append(.backtick)
            case "$":
                if next == "{" {
                    stack.append(.dollarBrace)
                    out.append(char); out.append("{")
                    index += 2; continue
                }
                if next == "(" {
                    // `$((` opens arithmetic — treat as `$(` + `(`
                    // so the matching `))` closes by popping the
                    // inner paren then the dollarParen.
                    if nextNext == "(" {
                        stack.append(.dollarParen)
                        stack.append(.paren)
                        out.append(char); out.append("("); out.append("(")
                        index += 3; continue
                    }
                    stack.append(.dollarParen)
                    out.append(char); out.append("(")
                    index += 2; continue
                }
            case "(":
                stack.append(.paren)
            case ")":
                if inside == .paren { stack.removeLast() } else if inside == .dollarParen { stack.removeLast() }
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

            out.append(char)
            index += 1
        }
        return out
    }

    /// One frame of `readSubstringField`'text nesting stack.
    enum NestState {
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
    static func splitOnUnescapedSlash(_ chars: [Character],
                                      from start: Int)
        -> (pattern: String, replacement: String) {
        var pattern = ""
        var index = start
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count {
                pattern.append(char)
                pattern.append(chars[index + 1])
                index += 2
                continue
            }
            if char == "/" { return (pattern, String(chars[(index + 1)...])) }
            pattern.append(char)
            index += 1
        }
        return (pattern, "")
    }

    /// Read a parameter name at `chars[index]` and advance `index`. Accepts
    /// single-character special parameters, a digit run (positional),
    /// or a regular identifier.
    static func readName(_ chars: [Character], _ index: inout Int) -> String {
        guard index < chars.count else { return "" }
        let first = chars[index]

        // Single-character special parameters.
        if "?$#!*@".contains(first) {
            index += 1
            return String(first)
        }

        // Digits (positional parameters). Treated as a single digit by
        // bash but we accept the full run for forward-compatibility.
        if first.isNumber {
            var text = ""
            while index < chars.count, chars[index].isNumber {
                text.append(chars[index])
                index += 1
            }
            return text
        }

        // Regular identifier — possibly with `[subscript]` suffix.
        if first.isLetter || first == "_" {
            var text = ""
            while index < chars.count,
                  chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
                text.append(chars[index])
                index += 1
            }
            // Optional `[subscript]` for indexed arrays. The
            // subscript text is preserved as part of the name so the
            // interpreter'text `lookup` can split it back out.
            if index < chars.count, chars[index] == "[" {
                let saved = index
                index += 1
                var sub = ""
                while index < chars.count, chars[index] != "]" {
                    sub.append(chars[index])
                    index += 1
                }
                if index < chars.count, chars[index] == "]" {
                    index += 1
                    text += "[\(sub)]"
                } else {
                    index = saved
                }
            }
            return text
        }

        return ""
    }
}
