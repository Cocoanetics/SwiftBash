import Foundation
import BashSyntax

extension Shell {

    /// Execute a `pipeline` node. Parts alternate between commands and
    /// `.pipe("|" | "|&")` separators, with an optional leading
    /// `.reservedWord("!")` that inverts the final exit status.
    ///
    /// Each stage runs in its own `Task` inside a `TaskGroup`, wired
    /// together by fresh ``OutputSink``s. Upstream stages write into a
    /// sink; the next stage's `stdin` is the sink's `bytes` stream.
    /// Downstream termination cancels upstream producers.
    func executePipeline(parts: [Node]) async throws -> ExitStatus {
        var i = 0
        var invert = false
        if !parts.isEmpty,
           case .reservedWord(let w) = parts[0].kind, w == "!"
        {
            invert = true
            i = 1
        }

        var stages: [Node] = []
        var pipeOps: [String] = []
        while i < parts.count {
            let node = parts[i]
            if case .pipe(let op) = node.kind {
                pipeOps.append(op)
            } else {
                stages.append(node)
            }
            i += 1
        }

        guard !stages.isEmpty else { return .success }

        // N-1 inter-stage sinks: stage i's stdout → stage i+1's stdin.
        let channels: [OutputSink] = (0..<max(0, stages.count - 1)).map { _ in
            OutputSink()
        }

        let outerStdin = stdin
        let outerStdout = stdout
        let outerStderr = stderr
        let envSnapshot = environment
        let commandRegistry = commands
        let sourceSnapshot = currentSource

        let status = try await withThrowingTaskGroup(
            of: (Int, ExitStatus).self
        ) { group in
            for (index, stage) in stages.enumerated() {
                let isLast = (index == stages.count - 1)
                let isFirst = (index == 0)
                let incomingSink = isFirst ? nil : channels[index - 1]
                let outgoingSink = isLast ? nil : channels[index]
                let mergeStderr = !isLast && pipeOps[index] == "|&"

                group.addTask {
                    let sub = Shell(
                        environment: envSnapshot,
                        stdout: outgoingSink ?? outerStdout,
                        stderr: mergeStderr
                            ? (outgoingSink ?? outerStderr)
                            : outerStderr,
                        commands: commandRegistry
                    )
                    sub.currentSource = sourceSnapshot
                    sub.stdin = incomingSink.map { InputSource(bytes: $0.bytes) }
                             ?? outerStdin

                    do {
                        let result = try await sub.execute(stage)
                        outgoingSink?.finish()
                        return (index, result)
                    } catch {
                        outgoingSink?.finish()
                        throw error
                    }
                }
            }

            var finalStatus = ExitStatus.success
            while true {
                do {
                    guard let (index, result) = try await group.next() else {
                        break
                    }
                    if index == stages.count - 1 {
                        finalStatus = result
                        // Downstream terminated — signal upstream to
                        // stop. Producers that check `Task.isCancelled`
                        // (including our cooperative `sleep`) unblock
                        // immediately.
                        group.cancelAll()
                    }
                } catch is CancellationError {
                    continue
                }
            }
            return finalStatus
        }

        lastExitStatus = invert
            ? (status.isSuccess ? .failure : .success)
            : status
        return lastExitStatus
    }
}
