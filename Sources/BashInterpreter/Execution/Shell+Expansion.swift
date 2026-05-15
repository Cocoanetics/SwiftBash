import Foundation
import BashSyntax

extension Shell {

    // Produce the runtime string value of a `.word` / `.assignment` node.
    //
    // Walks the raw characters of the word's range in `currentSource`,
    // stripping quotes and splicing in resolved values for each
    // substitution sub-node (`$VAR`, `${…}`, `$(…)`, `` `…` ``, `~`).
    // Sub-nodes are matched by their absolute source range — the AST
    // already tells us exactly where each substitution occurs.
    // swiftlint:disable:next cyclomatic_complexity function_body_length - quote/escape state machine
    func expand(word node: Node) async throws -> String {
        let parts: [Node]
        switch node.kind {
        case .word(_, let inner), .assignment(_, let inner):
            parts = inner
        default:
            return ""
        }

        let chars = Array(currentSource)
        let low = max(0, node.range.lowerBound)
        let high = min(chars.count, node.range.upperBound)
        guard low < high else { return "" }

        var queue = parts.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        var idx = low
        var inDouble = false

        while idx < high {
            if let head = queue.first, idx == head.range.lowerBound {
                result.append(try await resolve(part: head))
                idx = min(high, head.range.upperBound)
                queue.removeFirst()
                continue
            }
            let char = chars[idx]

            if char == "'", !inDouble {
                // `$'…'` ANSI-C quoting: the prior char (and the
                // last char already pushed to `result`) is the
                // marker. Run the body through bash's C-style
                // backslash decoder so assignments like
                // `esc=$'\033'` yield the ESC byte, not the literal
                // four characters. Same logic lives in
                // `Shell+Expansion+Argv.swift` for the command-arg
                // path; this branch covers assignment values and
                // anything else routed through `expand(word:)`.
                let isAnsiC = (idx > low && chars[idx - 1] == "$"
                               && !result.isEmpty
                               && result.last == "$")
                if isAnsiC {
                    result.removeLast()        // consume the `$`
                    idx += 1                   // consume the opening `'`
                    var body = ""
                    while idx < high, chars[idx] != "'" {
                        if chars[idx] == "\\", idx + 1 < high {
                            // Preserve the escape pair so the decoder
                            // sees `\'`, `\\` etc. intact.
                            body.append(chars[idx])
                            body.append(chars[idx + 1])
                            idx += 2
                            continue
                        }
                        body.append(chars[idx])
                        idx += 1
                    }
                    result += Self.decodeAnsiCEscapes(body)
                } else {
                    idx += 1
                    while idx < high, chars[idx] != "'" {
                        result.append(chars[idx])
                        idx += 1
                    }
                }
                if idx < high { idx += 1 }
                continue
            }
            if char == "\"" {
                inDouble.toggle()
                idx += 1
                continue
            }
            if char == "\\" {
                idx += 1
                if idx < high {
                    // POSIX: `\<newline>` is a line continuation — both
                    // characters are removed. Without this skip the
                    // newline would be re-emitted as a literal byte.
                    if chars[idx] == "\n" {
                        idx += 1
                        continue
                    }
                    result.append(chars[idx])
                    idx += 1
                }
                continue
            }

            result.append(char)
            idx += 1
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
                                            command: Node) async throws -> String {
        let direction: ProcessSubKind
        let chars = Array(currentSource)
        if part.range.lowerBound < chars.count,
           chars[part.range.lowerBound] == ">" {
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
        case "$": return "\(virtualPID)"
        case "!":
            // PID of the most recent background command, or empty if
            // none has been spawned in this shell tree yet.
            if let pid = await processTable.lastBackgroundPID {
                return "\(pid)"
            }
            return ""
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
        if let num = Int(body), num >= 1 {
            let idx = num - 1
            return idx < positionalParameters.count
                ? positionalParameters[idx]
                : ""
        }
        // `ParameterFormParser.parse` throws `BashInterpreterError`
        // for genuinely malformed bodies (`${var:1:}`, missing
        // closing brace, …). Bash reports those as a stderr
        // diagnostic plus a non-zero exit status, not a fatal
        // parser abort — surface them through the same
        // stderr+ShellExit shape the rest of parameter expansion
        // uses so the run boundary can record $? = 1.
        let form: ParameterForm
        do {
            form = try ParameterFormParser.parse(body)
        } catch let err as BashInterpreterError {
            stderr("\(errorLocationPrefix())\(err.description)\n")
            throw ShellExit(status: ExitStatus(1))
        }
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
