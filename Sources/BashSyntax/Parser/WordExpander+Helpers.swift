import Foundation

// Balanced-pair / backtick / arithmetic-body scanners used by
// `WordExpander.expand`. Split out from `WordExpander.swift` to keep
// that struct's body within the size budget.

extension WordExpander {

    // Consume a balanced `open`/`close` body starting at `from`; returns the
    // body (without the outer close) and the index one past the matching close.
    // swiftlint:disable:next cyclomatic_complexity
    func extractBalanced(
        chars: [Character], from start: Int,
        open: Character, close: Character
    ) throws -> (String, Int) {
        var depth = 1
        var pos = start
        var body = ""
        var passNext = false

        while pos < chars.count {
            let char = chars[pos]
            if passNext { passNext = false; body.append(char); pos += 1; continue }
            if char == "\\" { passNext = true; body.append(char); pos += 1; continue }
            if char == "'" {
                // skip single-quoted string verbatim
                body.append(char); pos += 1
                while pos < chars.count, chars[pos] != "'" {
                    body.append(chars[pos]); pos += 1
                }
                if pos < chars.count { body.append(chars[pos]); pos += 1 }
                continue
            }
            if char == "\"" {
                body.append(char); pos += 1
                while pos < chars.count, chars[pos] != "\"" {
                    if chars[pos] == "\\", pos + 1 < chars.count {
                        body.append(chars[pos]); body.append(chars[pos + 1]); pos += 2
                        continue
                    }
                    body.append(chars[pos]); pos += 1
                }
                if pos < chars.count { body.append(chars[pos]); pos += 1 }
                continue
            }
            if char == open {
                depth += 1
            } else if char == close {
                depth -= 1
                if depth == 0 { return (body, pos + 1) }
            }
            body.append(char)
            pos += 1
        }
        throw BashSyntaxError.parsing(
            message: "unmatched '\(open)' in expansion",
            source: "", position: pos)
    }

    // Consume chars until a non-escaped backtick, returning body and
    // index past the closing backtick.
    func extractBackticked(chars: [Character], from start: Int)
        throws -> (String, Int) {
        var pos = start
        var body = ""
        while pos < chars.count {
            let char = chars[pos]
            if char == "\\", pos + 1 < chars.count {
                body.append(char); body.append(chars[pos + 1]); pos += 2; continue
            }
            if char == "`" {
                return (body, pos + 1)
            }
            body.append(char); pos += 1
        }
        throw BashSyntaxError.parsing(
            message: "unmatched backtick",
            source: "", position: pos)
    }

    // Extract the body of a `$((…))` arithmetic substitution starting one
    // position past the opening `((`. Nested `()` balance normally; quoted
    // strings are skipped as opaque units. Returns the body text (without
    // the closing `))`) and the index one past the closing `))`.
    func extractArithmeticBody(chars: [Character], from start: Int)
        throws -> (String, Int) {
        var depth = 0
        var pos = start
        var body = ""

        while pos < chars.count {
            let char = chars[pos]
            if char == "\\", pos + 1 < chars.count {
                body.append(char); body.append(chars[pos + 1]); pos += 2; continue
            }
            if char == "'" || char == "\"" {
                body.append(char); pos += 1
                while pos < chars.count, chars[pos] != char {
                    if chars[pos] == "\\", pos + 1 < chars.count {
                        body.append(chars[pos]); body.append(chars[pos + 1]); pos += 2
                        continue
                    }
                    body.append(chars[pos]); pos += 1
                }
                if pos < chars.count { body.append(chars[pos]); pos += 1 }
                continue
            }
            if char == "(" {
                depth += 1; body.append(char); pos += 1; continue
            }
            if char == ")" {
                if depth == 0 {
                    if pos + 1 < chars.count, chars[pos + 1] == ")" {
                        return (body, pos + 2)
                    }
                    throw BashSyntaxError.parsing(
                        message: "expected `))` to close arithmetic",
                        source: "", position: pos)
                }
                depth -= 1; body.append(char); pos += 1; continue
            }
            body.append(char); pos += 1
        }
        throw BashSyntaxError.parsing(
            message: "unclosed `((`",
            source: "", position: pos)
    }
}
