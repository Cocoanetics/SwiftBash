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
    func expand(word node: Node) throws -> String {
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

        // Parts sorted by where they start in the source; we walk left-to-right
        // and splice as we hit each one.
        var queue = parts.sorted { $0.range.lowerBound < $1.range.lowerBound }

        var result = ""
        var i = lo

        while i < hi {
            if let head = queue.first, i == head.range.lowerBound {
                result.append(try resolve(part: head))
                i = min(hi, head.range.upperBound)
                queue.removeFirst()
                continue
            }
            let c = chars[i]

            // Single quote: copy contents verbatim (no expansion inside).
            if c == "'" {
                i += 1
                while i < hi, chars[i] != "'" {
                    result.append(chars[i])
                    i += 1
                }
                if i < hi { i += 1 } // consume closing quote
                continue
            }

            // Double quote: strip the quote chars; expansion continues normally.
            if c == "\"" {
                i += 1
                continue
            }

            // Backslash: escape next char (include it literally).
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
    private func resolve(part: Node) throws -> String {
        switch part.kind {
        case .parameter(let name):
            return resolveParameter(name)
        case .tilde(let raw):
            if raw == "~" {
                return environment["HOME"] ?? raw
            }
            // ~user forms are not implemented; leave literal.
            return raw
        case .commandSubstitution(let cmd):
            return try captureOutput(of: cmd)
        case .processSubstitution:
            throw BashInterpreterError.unimplemented("process substitution")
        case .arithmeticSubstitution:
            throw BashInterpreterError.unimplemented("arithmetic substitution evaluation")
        default:
            return ""
        }
    }

    /// Resolve a parameter expression. Handles plain names (`HOME`),
    /// special one-char parameters (`?`, `$`, `#`), and falls through to
    /// an empty string for anything unknown or complex (`${var:-x}` etc.
    /// is not yet evaluated — the full body is stored in the parameter).
    private func resolveParameter(_ expr: String) -> String {
        switch expr {
        case "?": return "\(lastExitStatus.code)"
        case "$": return "\(getpid())"
        case "#": return "0"
        case "0": return "swift-bash"
        default: break
        }
        // Plain variable reference.
        if expr.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return environment[expr] ?? ""
        }
        // `${…}` body of any shape — for the skeleton we only recognise
        // a bare name; anything else is surfaced as empty, matching the
        // conservative behaviour of expansion in a shell with `set -u` off.
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        if trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return environment[trimmed] ?? ""
        }
        return ""
    }

    /// Run `node` in a scope that captures stdout into a string.
    /// Trailing newlines are trimmed — matching bash's `$(…)` semantics.
    private func captureOutput(of node: Node) throws -> String {
        var buffer = ""
        let savedStdout = stdout
        stdout = { buffer.append($0) }
        defer { stdout = savedStdout }

        _ = try execute(node)
        while buffer.hasSuffix("\n") { buffer.removeLast() }
        return buffer
    }
}
