import Foundation
import BashSyntax

extension Shell {

    /// Produce the runtime string value of a `.word` / `.assignment` node.
    ///
    /// Walks the raw characters of the word's range in `currentSource`,
    /// stripping quotes and splicing in resolved values for each
    /// substitution sub-node (`$VAR`, `${…}`, `$(…)`, `` `…` ``, `~`).
    /// Sub-nodes are matched by their absolute source range — the AST
    /// already tells us exactly where each substitution occurs.
    func expand(word node: Node) async throws -> String {
        let parts: [Node]
        switch node.kind {
        case .word(_, let p), .assignment(_, let p):
            parts = p
        default:
            return ""
        }

        let chars = Array(currentSource)
        let lo = max(0, node.range.lowerBound)
        let hi = min(chars.count, node.range.upperBound)
        guard lo < hi else { return "" }

        var queue = parts.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        var i = lo

        while i < hi {
            if let head = queue.first, i == head.range.lowerBound {
                result.append(try await resolve(part: head))
                i = min(hi, head.range.upperBound)
                queue.removeFirst()
                continue
            }
            let c = chars[i]

            if c == "'" {
                i += 1
                while i < hi, chars[i] != "'" {
                    result.append(chars[i])
                    i += 1
                }
                if i < hi { i += 1 }
                continue
            }
            if c == "\"" {
                i += 1
                continue
            }
            if c == "\\" {
                i += 1
                if i < hi {
                    result.append(chars[i])
                    i += 1
                }
                continue
            }

            result.append(c)
            i += 1
        }
        return result
    }

    /// Resolve a single substitution sub-node to its string value.
    private func resolve(part: Node) async throws -> String {
        switch part.kind {
        case .parameter(let name):
            return try await resolveParameter(name)
        case .tilde(let raw):
            if raw == "~" { return environment["HOME"] ?? raw }
            return raw
        case .commandSubstitution(let cmd):
            return try await captureOutput(of: cmd)
        case .processSubstitution:
            throw BashInterpreterError.unimplemented("process substitution")
        case .arithmeticSubstitution(let expr):
            let value = try evaluateArithmetic(expr)
            return String(value)
        default:
            return ""
        }
    }

    /// Resolve a `.parameter(body)` sub-node to its runtime string value.
    func resolveParameter(_ body: String) async throws -> String {
        switch body {
        case "?": return "\(lastExitStatus.code)"
        case "$": return "\(getpid())"
        case "!": return "0"
        case "#": return "0"
        default: break
        }
        let form = try ParameterFormParser.parse(body)
        return try await applyParameterForm(form)
    }

    /// Run `node` in a scope that captures stdout into a string.
    /// Trailing newlines are trimmed — matching bash's `$(…)` semantics.
    private func captureOutput(of node: Node) async throws -> String {
        let sink = OutputSink()
        let savedStdout = stdout
        stdout = sink
        defer { stdout = savedStdout }

        _ = try await execute(node)
        sink.finish()
        var text = await sink.readAllString()
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
