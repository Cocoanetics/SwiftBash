import Foundation
import BashSyntax

extension Shell {

    // Expand a string using bash's "inside-double-quotes" rules:
    // parameter, arithmetic, and command substitution all fire;
    // word splitting and pathname expansion do *not*. Backslash
    // escapes only `$`, `` ` ``, `\`, and a trailing newline —
    // every other backslash stays literal.
    //
    // Used by:
    // - `<<DELIMITER` heredocs whose delimiter was *unquoted*
    //   (`<<'EOF'`, `<<"EOF"`, `<<\EOF` skip this and feed the
    //   body verbatim).
    // - The "word" inside a parameter-form operator —
    //   `${foo:-$(date)}` lets the default value run a command.
    //
    // Multi-prefix scanner walks `\`, backtick, `$((`, `$(`, `${`,
    // `$name`, etc. inline; splitting per-prefix would force a state
    // struct just to thread `cursor` and `result`.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func expandHeredocBody(_ body: String) async throws -> String {
        var result = ""
        let chars = Array(body)
        var cursor = 0

        while cursor < chars.count {
            let char = chars[cursor]

            if char == "\\" {
                // Inside heredoc bodies (and double quotes), backslash
                // only escapes a small set; otherwise it's literal.
                if cursor + 1 < chars.count {
                    let next = chars[cursor + 1]
                    if next == "$" || next == "`" || next == "\\" || next == "\n" {
                        if next != "\n" {
                            result.append(next)
                        }
                        cursor += 2
                        continue
                    }
                }
                result.append("\\")
                cursor += 1
                continue
            }

            if char == "`" {
                let (cmdSrc, end) = try findBacktickBody(chars: chars, start: cursor + 1)
                let value = try await runCommandSubstitution(source: cmdSrc)
                result.append(value)
                cursor = end
                continue
            }

            if char == "$", cursor + 1 < chars.count {
                let next = chars[cursor + 1]

                // $((expr))
                if next == "(", cursor + 2 < chars.count, chars[cursor + 2] == "(" {
                    let (expr, end) = try findArithmeticBody(
                        chars: chars, start: cursor + 3)
                    let value = try await evaluateArithmetic(expr)
                    result.append(String(value))
                    cursor = end
                    continue
                }
                // $(cmd)
                if next == "(" {
                    let (src, end) = try findBalancedParenBody(
                        chars: chars, start: cursor + 2)
                    let value = try await runCommandSubstitution(source: src)
                    result.append(value)
                    cursor = end
                    continue
                }
                // ${name…}
                if next == "{" {
                    let (innerBody, end) = try findBracedBody(
                        chars: chars, start: cursor + 2)
                    let value = try await resolveParameter(innerBody)
                    result.append(value)
                    cursor = end
                    continue
                }
                // $? $$ $! $# $@ $* $0..$9
                if isSpecialParamChar(next) || next.isASCIIDigit {
                    let value = try await resolveParameter(String(next))
                    result.append(value)
                    cursor += 2
                    continue
                }
                // $name
                if next.isLetter || next == "_" {
                    var probe = cursor + 1
                    while probe < chars.count,
                          chars[probe].isLetter || chars[probe] == "_" || chars[probe].isASCIIDigit {
                        probe += 1
                    }
                    let name = String(chars[(cursor + 1)..<probe])
                    result.append(try await resolveParameter(name))
                    cursor = probe
                    continue
                }
                // Lone `$` — literal.
                result.append("$")
                cursor += 1
                continue
            }

            result.append(char)
            cursor += 1
        }

        return result
    }

    // MARK: Body scanners

    /// Read up to the matching unescaped `` ` ``. Returns the body
    /// (without backticks) and the index immediately after the
    /// closing backtick.
    private func findBacktickBody(chars: [Character], start: Int)
        throws -> (String, Int) {
        var cursor = start
        var body = ""
        while cursor < chars.count {
            let char = chars[cursor]
            if char == "\\", cursor + 1 < chars.count {
                // Inside backticks, `\$`, `` \` ``, `\\` escape.
                let next = chars[cursor + 1]
                if next == "$" || next == "`" || next == "\\" {
                    body.append(next)
                    cursor += 2
                    continue
                }
                body.append(char)
                cursor += 1
                continue
            }
            if char == "`" {
                return (body, cursor + 1)
            }
            body.append(char)
            cursor += 1
        }
        throw BashInterpreterError.io(
            "heredoc body: unterminated backtick substitution")
    }

    // Read `$( … )` body. `start` points at the char after the
    // opening `(`. Tracks nested parens; respects single and double
    // quotes inside.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func findBalancedParenBody(chars: [Character], start: Int)
        throws -> (String, Int) {
        var depth = 1
        var cursor = start
        var body = ""
        while cursor < chars.count {
            let char = chars[cursor]
            if char == "\\", cursor + 1 < chars.count {
                body.append(char)
                body.append(chars[cursor + 1])
                cursor += 2
                continue
            }
            if char == "'" {
                body.append(char)
                cursor += 1
                while cursor < chars.count, chars[cursor] != "'" {
                    body.append(chars[cursor])
                    cursor += 1
                }
                if cursor < chars.count {
                    body.append(chars[cursor])
                    cursor += 1
                }
                continue
            }
            if char == "\"" {
                body.append(char)
                cursor += 1
                while cursor < chars.count, chars[cursor] != "\"" {
                    if chars[cursor] == "\\", cursor + 1 < chars.count {
                        body.append(chars[cursor])
                        body.append(chars[cursor + 1])
                        cursor += 2
                        continue
                    }
                    body.append(chars[cursor])
                    cursor += 1
                }
                if cursor < chars.count {
                    body.append(chars[cursor])
                    cursor += 1
                }
                continue
            }
            if char == "(" {
                depth += 1
                body.append(char)
                cursor += 1
                continue
            }
            if char == ")" {
                depth -= 1
                if depth == 0 {
                    return (body, cursor + 1)
                }
                body.append(char)
                cursor += 1
                continue
            }
            body.append(char)
            cursor += 1
        }
        throw BashInterpreterError.io(
            "heredoc body: unterminated $( substitution")
    }

    /// Read `$(( … ))` body. `start` points at the first char after
    /// the opening `((`. Tracks nested *inner* parens within the
    /// arithmetic expression, and stops at the first `))` that closes
    /// at depth-0.
    private func findArithmeticBody(chars: [Character], start: Int)
        throws -> (String, Int) {
        var inner = 0  // depth of inner ( ) within the expression
        var cursor = start
        var body = ""
        while cursor < chars.count {
            let char = chars[cursor]
            if char == "(" {
                inner += 1
                body.append(char)
                cursor += 1
                continue
            }
            if char == ")" {
                if inner == 0 {
                    // Outer close: must be `))`.
                    if cursor + 1 < chars.count, chars[cursor + 1] == ")" {
                        return (body, cursor + 2)
                    }
                    throw BashInterpreterError.io(
                        "heredoc body: malformed arithmetic substitution")
                }
                inner -= 1
                body.append(char)
                cursor += 1
                continue
            }
            body.append(char)
            cursor += 1
        }
        throw BashInterpreterError.io(
            "heredoc body: unterminated $((  substitution")
    }

    /// Read `${ … }` body. Tracks brace nesting so things like
    /// `${X:-${Y}}` work.
    private func findBracedBody(chars: [Character], start: Int)
        throws -> (String, Int) {
        var depth = 1
        var cursor = start
        var body = ""
        while cursor < chars.count {
            let char = chars[cursor]
            if char == "{" {
                depth += 1
                body.append(char)
                cursor += 1
                continue
            }
            if char == "}" {
                depth -= 1
                if depth == 0 { return (body, cursor + 1) }
                body.append(char)
                cursor += 1
                continue
            }
            body.append(char)
            cursor += 1
        }
        throw BashInterpreterError.io(
            "heredoc body: unterminated ${ substitution")
    }

    /// Run a synthetic command substitution: parse `source` as bash,
    /// run it with stdout captured, return the captured string with
    /// trailing newlines trimmed (matching `$(…)` semantics).
    private func runCommandSubstitution(source: String) async throws -> String {
        let parts = try BashSyntax.parse(source)
        let sink = OutputSink()
        let savedStdout = stdout
        let savedSource = currentSource
        stdout = sink
        currentSource = source
        defer {
            stdout = savedStdout
            currentSource = savedSource
        }
        for node in parts {
            _ = try await execute(node)
        }
        sink.finish()
        var text = await sink.readAllString()
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Whether `c` is one of bash's single-character special params
    /// (other than 0–9). `0` is a digit, handled separately.
    private func isSpecialParamChar(_ char: Character) -> Bool {
        switch char {
        case "@", "*", "#", "?", "$", "!", "-": return true
        default: return false
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
