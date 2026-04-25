import Foundation
import BashSyntax

extension Shell {

    /// Expand a string using bash's "inside-double-quotes" rules:
    /// parameter, arithmetic, and command substitution all fire;
    /// word splitting and pathname expansion do *not*. Backslash
    /// escapes only `$`, `` ` ``, `\`, and a trailing newline —
    /// every other backslash stays literal.
    ///
    /// Used by:
    /// - `<<DELIMITER` heredocs whose delimiter was *unquoted*
    ///   (`<<'EOF'`, `<<"EOF"`, `<<\EOF` skip this and feed the
    ///   body verbatim).
    /// - The "word" inside a parameter-form operator —
    ///   `${foo:-$(date)}` lets the default value run a command.
    func expandHeredocBody(_ body: String) async throws -> String {
        var result = ""
        let chars = Array(body)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c == "\\" {
                // Inside heredoc bodies (and double quotes), backslash
                // only escapes a small set; otherwise it's literal.
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "$" || next == "`" || next == "\\" || next == "\n" {
                        if next != "\n" {
                            result.append(next)
                        }
                        i += 2
                        continue
                    }
                }
                result.append("\\")
                i += 1
                continue
            }

            if c == "`" {
                let (cmdSrc, end) = try findBacktickBody(chars: chars, start: i + 1)
                let value = try await runCommandSubstitution(source: cmdSrc)
                result.append(value)
                i = end
                continue
            }

            if c == "$", i + 1 < chars.count {
                let next = chars[i + 1]

                // $((expr))
                if next == "(", i + 2 < chars.count, chars[i + 2] == "(" {
                    let (expr, end) = try findArithmeticBody(
                        chars: chars, start: i + 3)
                    let value = try await evaluateArithmetic(expr)
                    result.append(String(value))
                    i = end
                    continue
                }
                // $(cmd)
                if next == "(" {
                    let (src, end) = try findBalancedParenBody(
                        chars: chars, start: i + 2)
                    let value = try await runCommandSubstitution(source: src)
                    result.append(value)
                    i = end
                    continue
                }
                // ${name…}
                if next == "{" {
                    let (innerBody, end) = try findBracedBody(
                        chars: chars, start: i + 2)
                    let value = try await resolveParameter(innerBody)
                    result.append(value)
                    i = end
                    continue
                }
                // $? $$ $! $# $@ $* $0..$9
                if isSpecialParamChar(next) || next.isASCIIDigit {
                    let value = try await resolveParameter(String(next))
                    result.append(value)
                    i += 2
                    continue
                }
                // $name
                if next.isLetter || next == "_" {
                    var j = i + 1
                    while j < chars.count,
                          chars[j].isLetter || chars[j] == "_" || chars[j].isASCIIDigit
                    {
                        j += 1
                    }
                    let name = String(chars[(i + 1)..<j])
                    result.append(try await resolveParameter(name))
                    i = j
                    continue
                }
                // Lone `$` — literal.
                result.append("$")
                i += 1
                continue
            }

            result.append(c)
            i += 1
        }

        return result
    }

    // MARK: Body scanners

    /// Read up to the matching unescaped `` ` ``. Returns the body
    /// (without backticks) and the index immediately after the
    /// closing backtick.
    private func findBacktickBody(chars: [Character], start: Int)
        throws -> (String, Int)
    {
        var i = start
        var body = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                // Inside backticks, `\$`, `` \` ``, `\\` escape.
                let next = chars[i + 1]
                if next == "$" || next == "`" || next == "\\" {
                    body.append(next)
                    i += 2
                    continue
                }
                body.append(c)
                i += 1
                continue
            }
            if c == "`" {
                return (body, i + 1)
            }
            body.append(c)
            i += 1
        }
        throw BashInterpreterError.io(
            "heredoc body: unterminated backtick substitution")
    }

    /// Read `$( … )` body. `start` points at the char after the
    /// opening `(`. Tracks nested parens; respects single and double
    /// quotes inside.
    private func findBalancedParenBody(chars: [Character], start: Int)
        throws -> (String, Int)
    {
        var depth = 1
        var i = start
        var body = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                body.append(c)
                body.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "'" {
                body.append(c)
                i += 1
                while i < chars.count, chars[i] != "'" {
                    body.append(chars[i]); i += 1
                }
                if i < chars.count { body.append(chars[i]); i += 1 }
                continue
            }
            if c == "\"" {
                body.append(c)
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        body.append(chars[i]); body.append(chars[i + 1])
                        i += 2; continue
                    }
                    body.append(chars[i]); i += 1
                }
                if i < chars.count { body.append(chars[i]); i += 1 }
                continue
            }
            if c == "(" {
                depth += 1
                body.append(c)
                i += 1
                continue
            }
            if c == ")" {
                depth -= 1
                if depth == 0 {
                    return (body, i + 1)
                }
                body.append(c)
                i += 1
                continue
            }
            body.append(c)
            i += 1
        }
        throw BashInterpreterError.io(
            "heredoc body: unterminated $( substitution")
    }

    /// Read `$(( … ))` body. `start` points at the first char after
    /// the opening `((`. Tracks nested *inner* parens within the
    /// arithmetic expression, and stops at the first `))` that closes
    /// at depth-0.
    private func findArithmeticBody(chars: [Character], start: Int)
        throws -> (String, Int)
    {
        var inner = 0  // depth of inner ( ) within the expression
        var i = start
        var body = ""
        while i < chars.count {
            let c = chars[i]
            if c == "(" {
                inner += 1
                body.append(c)
                i += 1
                continue
            }
            if c == ")" {
                if inner == 0 {
                    // Outer close: must be `))`.
                    if i + 1 < chars.count, chars[i + 1] == ")" {
                        return (body, i + 2)
                    }
                    throw BashInterpreterError.io(
                        "heredoc body: malformed arithmetic substitution")
                }
                inner -= 1
                body.append(c)
                i += 1
                continue
            }
            body.append(c)
            i += 1
        }
        throw BashInterpreterError.io(
            "heredoc body: unterminated $((  substitution")
    }

    /// Read `${ … }` body. Tracks brace nesting so things like
    /// `${X:-${Y}}` work.
    private func findBracedBody(chars: [Character], start: Int)
        throws -> (String, Int)
    {
        var depth = 1
        var i = start
        var body = ""
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                depth += 1; body.append(c); i += 1; continue
            }
            if c == "}" {
                depth -= 1
                if depth == 0 { return (body, i + 1) }
                body.append(c); i += 1; continue
            }
            body.append(c)
            i += 1
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
    private func isSpecialParamChar(_ c: Character) -> Bool {
        switch c {
        case "@", "*", "#", "?", "$", "!", "-": return true
        default: return false
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
