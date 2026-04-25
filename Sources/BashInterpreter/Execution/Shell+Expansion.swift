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
    func resolve(part: Node) async throws -> String {
        switch part.kind {
        case .parameter(let name):
            return try await resolveParameter(name)
        case .tilde(let raw):
            if raw == "~" { return environment["HOME"] ?? raw }
            return raw
        case .commandSubstitution(let cmd):
            return try await captureOutput(of: cmd)
        case .processSubstitution(let cmd):
            return try await resolveProcessSubstitution(part: part, command: cmd)
        case .arithmeticSubstitution(let expr):
            let value = try await evaluateArithmetic(expr)
            return String(value)
        default:
            return ""
        }
    }

    /// Implement `<(cmd)` and `>(cmd)` against the in-process file
    /// system. These don't use real fds — we synthesise a temp file in
    /// ``Shell/fileSystem``, pre-fill it (input case) or post-drain it
    /// (output case), and substitute the path into argv.
    ///
    /// **Limitations vs. `/bin/bash`:**
    /// - Not streaming: `<(cmd)` waits for `cmd` to finish before the
    ///   outer command starts, and `>(cmd)` waits for the outer
    ///   command to finish before `cmd` runs.
    /// - Concurrent tools that rely on overlapping execution
    ///   (`<(tail -f log)`) won't work; bounded outputs (`diff <(a) <(b)`)
    ///   work fine.
    private func resolveProcessSubstitution(part: Node,
                                            command: Node) async throws -> String
    {
        let direction: ProcessSub.Kind
        let chars = Array(currentSource)
        if part.range.lowerBound < chars.count,
           chars[part.range.lowerBound] == ">"
        {
            direction = .output
        } else {
            direction = .input
        }

        switch direction {
        case .input:
            // Run the inner command, capture its stdout, write to a
            // temp file, hand back the path.
            let path = try await fileSystem.makeTempPath(prefix: "procsub-in")
            let captured = try await captureBytes(of: command)
            try await fileSystem.writeData(captured, to: path, append: false)
            pendingProcessSubs.append(
                ProcessSub(kind: .input, path: path, consumer: nil))
            return path

        case .output:
            // Reserve a path now; the outer command writes to it.
            // After the outer command finishes, we read the path and
            // feed it to `command` as stdin.
            let path = try await fileSystem.makeTempPath(prefix: "procsub-out")
            try await fileSystem.writeData(Data(), to: path, append: false)
            pendingProcessSubs.append(
                ProcessSub(kind: .output, path: path, consumer: command))
            return path
        }
    }

    /// Run `node` in a scope that captures stdout as raw bytes
    /// (binary-safe — used by `<(cmd)`).
    private func captureBytes(of node: Node) async throws -> Data {
        let sink = OutputSink()
        let savedStdout = stdout
        stdout = sink
        defer { stdout = savedStdout }
        _ = try await execute(node)
        sink.finish()
        return await sink.readAllData()
    }

    /// Resolve a `.parameter(body)` sub-node to its runtime string value.
    func resolveParameter(_ body: String) async throws -> String {
        switch body {
        case "?": return "\(lastExitStatus.code)"
        case "$": return "\(getpid())"
        case "!": return "0"
        case "#": return "\(positionalParameters.count)"
        case "0": return scriptName
        case "@", "*":
            // Both join with the first IFS char (default: space). We
            // don't model "$@" vs $@ argv-splitting yet — both produce
            // a single space-joined string. The for-loop word splitter
            // breaks unquoted substitutions back apart on whitespace.
            return positionalParameters.joined(separator: " ")
        default: break
        }
        // `$1`, `$2`, … `${10}`, `${42}`
        if let n = Int(body), n >= 1 {
            let idx = n - 1
            return idx < positionalParameters.count
                ? positionalParameters[idx]
                : ""
        }
        let form = try ParameterFormParser.parse(body)
        return try await applyParameterForm(form)
    }

    /// Run `node` in a scope that captures stdout into a string.
    /// Trailing newlines are trimmed — matching bash's `$(…)` semantics.
    func captureOutput(of node: Node) async throws -> String {
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
