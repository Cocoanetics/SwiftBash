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

    // The bash word grammar covers process subst, every `$…` variant,
    // backticks, tilde, escapes, and both quote styles; one branch per
    // rule keeps the loop readable.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func expand(token: Token) throws -> ExpansionResult {
        let chars = Array(token.value)
        let origin = token.range.lowerBound

        var parts: [Node] = []
        var output = ""
        var pos = 0
        // Tracks whether we're currently inside a "..." run. Bash's
        // backslash rules differ from outside: inside dquote, `\` only
        // escapes `$`, `\``, `"`, `\` and newline — every other `\X`
        // is preserved as two characters (e.g. `\n` stays `\n`).
        var inDouble = false

        while pos < chars.count {
            let char = chars[pos]

            // Process substitution <(...) or >(...)
            if char == "<" || char == ">",
               pos + 1 < chars.count,
               chars[pos + 1] == "(" {
                let opStart = pos                         // position of '<' or '>'
                let bodyStart = pos + 2                   // first char of body
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
                pos = endIdx
                continue
            }

            if char == "$", pos + 1 < chars.count {
                let next = chars[pos + 1]

                // $(...)
                if next == "(" {
                    // `$((…))` arithmetic substitution — emit a node carrying
                    // the raw expression body (without the outer parens).
                    if pos + 2 < chars.count, chars[pos + 2] == "(" {
                        let opStart = pos                       // `$`
                        let bodyStart = pos + 3                 // first body char
                        let (body, afterIdx) = try extractArithmeticBody(
                            chars: chars, from: bodyStart)
                        let node = Node(
                            kind: .arithmeticSubstitution(body),
                            range: (origin + opStart)..<(origin + afterIdx))
                        parts.append(node)
                        output.append(String(chars[opStart..<afterIdx]))
                        pos = afterIdx
                        continue
                    }
                    let opStart = pos                 // `$`
                    let bodyStart = pos + 2           // first char of body
                    let (body, endIdx) = try extractBalanced(
                        chars: chars, from: bodyStart, open: "(", close: ")")
                    let absBodyOffset = origin + bodyStart
                    let inner = try parseBody(body, absBodyOffset)
                    let node = Node(
                        kind: .commandSubstitution(command: inner),
                        range: (origin + opStart)..<(origin + endIdx))
                    parts.append(node)
                    output.append(String(chars[opStart..<endIdx]))
                    pos = endIdx
                    continue
                }

                // ${...}
                if next == "{" {
                    let start = pos
                    let bodyStart = pos + 2
                    let (body, endIdx) = try extractBalanced(
                        chars: chars, from: bodyStart, open: "{", close: "}")
                    let node = Node(
                        kind: .parameter(body),
                        range: (origin + start)..<(origin + endIdx))
                    parts.append(node)
                    output.append(String(chars[start..<endIdx]))
                    pos = endIdx
                    continue
                }

                // Special parameters: $0..$9, $$, $#, $?, $-, $!, $*, $@
                if "0123456789$#?-!*@".contains(next) {
                    let node = Node(
                        kind: .parameter(String(next)),
                        range: (origin + pos)..<(origin + pos + 2))
                    parts.append(node)
                    output.append("$")
                    output.append(next)
                    pos += 2
                    continue
                }

                // $name
                if next.isLetter || next == "_" {
                    var scan = pos + 1
                    while scan < chars.count,
                          chars[scan].isLetter
                            || chars[scan].isNumber
                            || chars[scan] == "_" {
                        scan += 1
                    }
                    let name = String(chars[(pos + 1)..<scan])
                    let node = Node(
                        kind: .parameter(name),
                        range: (origin + pos)..<(origin + scan))
                    parts.append(node)
                    output.append(String(chars[pos..<scan]))
                    pos = scan
                    continue
                }

                // Unrecognised `$` — literal
                output.append(char)
                pos += 1
                continue
            }

            // Backticks
            if char == "`" {
                let opStart = pos
                let bodyStart = pos + 1
                let (body, endIdx) = try extractBackticked(chars: chars, from: bodyStart)
                let absBodyOffset = origin + bodyStart
                let inner = try parseBody(body, absBodyOffset)
                let node = Node(
                    kind: .commandSubstitution(command: inner),
                    range: (origin + opStart)..<(origin + endIdx))
                parts.append(node)
                output.append(String(chars[opStart..<endIdx]))
                pos = endIdx
                continue
            }

            // Tilde at word start — expand as tilde node.
            if char == "~", pos == 0, !token.flags.contains(.doubleQuoted) {
                var scan = 1
                while scan < chars.count,
                      chars[scan] != "/", chars[scan] != "\\",
                      chars[scan] != "'", chars[scan] != "\"",
                      chars[scan] != ":" {
                    scan += 1
                }
                let val = String(chars[0..<scan])
                let node = Node(
                    kind: .tilde(val),
                    range: (origin + 0)..<(origin + scan))
                parts.append(node)
                output.append(val)
                pos = scan
                continue
            }

            // Backslash escape
            if char == "\\", pos + 1 < chars.count {
                let next = chars[pos + 1]
                if inDouble, !"$`\"\\\n".contains(next) {
                    // Inside "..." bash keeps `\X` literal unless X is
                    // one of the escape-meaningful chars.
                    output.append(char)
                    output.append(next)
                } else {
                    output.append(next)
                }
                pos += 2
                continue
            }

            // Quotes are removed during expansion.
            if char == "\"" {
                inDouble.toggle()
                pos += 1
                continue
            }
            if char == "'", !inDouble {
                // Copy contents verbatim up to the closing '.
                var scan = pos + 1
                while scan < chars.count, chars[scan] != "'" {
                    output.append(chars[scan])
                    scan += 1
                }
                // consume the closing quote if present
                pos = (scan < chars.count) ? scan + 1 : scan
                continue
            }

            output.append(char)
            pos += 1
        }

        return ExpansionResult(parts: parts, expanded: output)
    }

    // Balanced-pair / backtick / arithmetic-body scanners live in
    // `WordExpander+Helpers.swift`.
}
