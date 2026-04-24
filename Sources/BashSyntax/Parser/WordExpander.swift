import Foundation

/// Expands a WORD token value into its substitution sub-nodes (command
/// substitutions, process substitutions, parameter expansions, tildes) and
/// returns the value with quote characters removed.
///
/// The caller supplies ``parseBody`` which is used to recursively parse the
/// body of any command/process substitution. `parseBody` receives the raw
/// substring and the absolute offset in the original source; it should return
/// a `Node` whose `range` uses absolute coordinates.
struct WordExpander {
    let parseBody: (_ body: String, _ baseOffset: Int) throws -> Node

    struct ExpansionResult {
        var parts: [Node]
        var expanded: String
    }

    func expand(token: Token) throws -> ExpansionResult {
        let chars = Array(token.value)
        let origin = token.range.lowerBound

        var parts: [Node] = []
        var output = ""
        var i = 0

        while i < chars.count {
            let c = chars[i]

            // Process substitution <(...) or >(...)
            if (c == "<" || c == ">"),
               i + 1 < chars.count,
               chars[i + 1] == "("
            {
                let opStart = i                           // position of '<' or '>'
                let bodyStart = i + 2                     // first char of body
                let (body, endIdx) = try extractBalanced(
                    chars: chars, from: bodyStart, open: "(", close: ")")
                // `endIdx` is the position of the matching `)` + 1 (one past).
                // Parse the body (without the parens) as a bash command.
                let absBodyOffset = origin + bodyStart
                let inner = try parseBody(body, absBodyOffset)
                let procNode = Node(
                    kind: .processSubstitution(command: inner),
                    range: (origin + opStart)..<(origin + endIdx))
                parts.append(procNode)
                output.append(String(chars[opStart..<endIdx]))
                i = endIdx
                continue
            }

            if c == "$", i + 1 < chars.count {
                let next = chars[i + 1]

                // $(...)
                if next == "(" {
                    // `$((…))` arithmetic substitution — emit a node carrying
                    // the raw expression body (without the outer parens).
                    if i + 2 < chars.count, chars[i + 2] == "(" {
                        let opStart = i                         // `$`
                        let bodyStart = i + 3                   // first body char
                        let (body, afterIdx) = try extractArithmeticBody(
                            chars: chars, from: bodyStart)
                        let node = Node(
                            kind: .arithmeticSubstitution(body),
                            range: (origin + opStart)..<(origin + afterIdx))
                        parts.append(node)
                        output.append(String(chars[opStart..<afterIdx]))
                        i = afterIdx
                        continue
                    }
                    let opStart = i                   // `$`
                    let bodyStart = i + 2             // first char of body
                    let (body, endIdx) = try extractBalanced(
                        chars: chars, from: bodyStart, open: "(", close: ")")
                    let absBodyOffset = origin + bodyStart
                    let inner = try parseBody(body, absBodyOffset)
                    let node = Node(
                        kind: .commandSubstitution(command: inner),
                        range: (origin + opStart)..<(origin + endIdx))
                    parts.append(node)
                    output.append(String(chars[opStart..<endIdx]))
                    i = endIdx
                    continue
                }

                // ${...}
                if next == "{" {
                    let start = i
                    let bodyStart = i + 2
                    let (body, endIdx) = try extractBalanced(
                        chars: chars, from: bodyStart, open: "{", close: "}")
                    let node = Node(
                        kind: .parameter(body),
                        range: (origin + start)..<(origin + endIdx))
                    parts.append(node)
                    output.append(String(chars[start..<endIdx]))
                    i = endIdx
                    continue
                }

                // Special parameters: $0..$9, $$, $#, $?, $-, $!, $*, $@
                if "0123456789$#?-!*@".contains(next) {
                    let node = Node(
                        kind: .parameter(String(next)),
                        range: (origin + i)..<(origin + i + 2))
                    parts.append(node)
                    output.append("$")
                    output.append(next)
                    i += 2
                    continue
                }

                // $name
                if next.isLetter || next == "_" {
                    var j = i + 1
                    while j < chars.count,
                          (chars[j].isLetter || chars[j].isNumber || chars[j] == "_")
                    {
                        j += 1
                    }
                    let name = String(chars[(i + 1)..<j])
                    let node = Node(
                        kind: .parameter(name),
                        range: (origin + i)..<(origin + j))
                    parts.append(node)
                    output.append(String(chars[i..<j]))
                    i = j
                    continue
                }

                // Unrecognised `$` — literal
                output.append(c)
                i += 1
                continue
            }

            // Backticks
            if c == "`" {
                let opStart = i
                let bodyStart = i + 1
                let (body, endIdx) = try extractBackticked(chars: chars, from: bodyStart)
                let absBodyOffset = origin + bodyStart
                let inner = try parseBody(body, absBodyOffset)
                let node = Node(
                    kind: .commandSubstitution(command: inner),
                    range: (origin + opStart)..<(origin + endIdx))
                parts.append(node)
                output.append(String(chars[opStart..<endIdx]))
                i = endIdx
                continue
            }

            // Tilde at word start — expand as tilde node.
            if c == "~", i == 0, !token.flags.contains(.doubleQuoted) {
                var j = 1
                while j < chars.count,
                      chars[j] != "/", chars[j] != "\\",
                      chars[j] != "'", chars[j] != "\"",
                      chars[j] != ":"
                {
                    j += 1
                }
                let val = String(chars[0..<j])
                let node = Node(
                    kind: .tilde(val),
                    range: (origin + 0)..<(origin + j))
                parts.append(node)
                output.append(val)
                i = j
                continue
            }

            // Backslash escape
            if c == "\\", i + 1 < chars.count {
                output.append(chars[i + 1])
                i += 2
                continue
            }

            // Quotes are removed during expansion.
            if c == "\"" {
                i += 1
                continue
            }
            if c == "'" {
                // Copy contents verbatim up to the closing '.
                var j = i + 1
                while j < chars.count, chars[j] != "'" {
                    output.append(chars[j])
                    j += 1
                }
                // consume the closing quote if present
                i = (j < chars.count) ? j + 1 : j
                continue
            }

            output.append(c)
            i += 1
        }

        return ExpansionResult(parts: parts, expanded: output)
    }

    // MARK: Helpers

    /// Consume a balanced `open`/`close` body starting at `from`; returns the
    /// body (without the outer close) and the index one past the matching close.
    private func extractBalanced(
        chars: [Character], from start: Int,
        open: Character, close: Character
    ) throws -> (String, Int) {
        var depth = 1
        var i = start
        var body = ""
        var passNext = false

        while i < chars.count {
            let c = chars[i]
            if passNext { passNext = false; body.append(c); i += 1; continue }
            if c == "\\" { passNext = true; body.append(c); i += 1; continue }
            if c == "'" {
                // skip single-quoted string verbatim
                body.append(c); i += 1
                while i < chars.count, chars[i] != "'" {
                    body.append(chars[i]); i += 1
                }
                if i < chars.count { body.append(chars[i]); i += 1 }
                continue
            }
            if c == "\"" {
                body.append(c); i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        body.append(chars[i]); body.append(chars[i + 1]); i += 2
                        continue
                    }
                    body.append(chars[i]); i += 1
                }
                if i < chars.count { body.append(chars[i]); i += 1 }
                continue
            }
            if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 { return (body, i + 1) }
            }
            body.append(c)
            i += 1
        }
        throw BashSyntaxError.parsing(
            message: "unmatched '\(open)' in expansion",
            source: "", position: i)
    }

    /// Consume chars until a non-escaped backtick, returning body and
    /// index past the closing backtick.
    private func extractBackticked(chars: [Character], from start: Int)
        throws -> (String, Int)
    {
        var i = start
        var body = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                body.append(c); body.append(chars[i + 1]); i += 2; continue
            }
            if c == "`" {
                return (body, i + 1)
            }
            body.append(c); i += 1
        }
        throw BashSyntaxError.parsing(
            message: "unmatched backtick",
            source: "", position: i)
    }

    /// Extract the body of a `$((…))` arithmetic substitution starting one
    /// position past the opening `((`. Nested `()` balance normally; quoted
    /// strings are skipped as opaque units. Returns the body text (without
    /// the closing `))`) and the index one past the closing `))`.
    private func extractArithmeticBody(chars: [Character], from start: Int)
        throws -> (String, Int)
    {
        var depth = 0
        var i = start
        var body = ""

        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                body.append(c); body.append(chars[i + 1]); i += 2; continue
            }
            if c == "'" || c == "\"" {
                body.append(c); i += 1
                while i < chars.count, chars[i] != c {
                    if chars[i] == "\\", i + 1 < chars.count {
                        body.append(chars[i]); body.append(chars[i + 1]); i += 2
                        continue
                    }
                    body.append(chars[i]); i += 1
                }
                if i < chars.count { body.append(chars[i]); i += 1 }
                continue
            }
            if c == "(" {
                depth += 1; body.append(c); i += 1; continue
            }
            if c == ")" {
                if depth == 0 {
                    if i + 1 < chars.count, chars[i + 1] == ")" {
                        return (body, i + 2)
                    }
                    throw BashSyntaxError.parsing(
                        message: "expected `))` to close arithmetic",
                        source: "", position: i)
                }
                depth -= 1; body.append(c); i += 1; continue
            }
            body.append(c); i += 1
        }
        throw BashSyntaxError.parsing(
            message: "unclosed `((`",
            source: "", position: i)
    }
}
