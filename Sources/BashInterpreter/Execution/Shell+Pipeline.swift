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
        // Single source-of-truth for what propagates: copy() clones
        // every inheritable field. Per-stage we then patch only the
        // stdio that's actually different (own piped sink vs. the
        // outer stdout/stderr, possibly merged for `|&`).
        let template = self  // captured for use in per-stage closure

        let pipefailMode = pipefail
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
                    let sub = template.copy()
                    sub.stdout = outgoingSink ?? outerStdout
                    sub.stderr = mergeStderr
                        ? (outgoingSink ?? outerStderr)
                        : outerStderr
                    sub.stdin = incomingSink.map { InputSource(bytes: $0.bytes) }
                             ?? outerStdin

                    do {
                        let result = try await sub.withCurrent {
                            try await sub.execute(stage)
                        }
                        outgoingSink?.finish()
                        return (index, result)
                    } catch is CancellationError {
                        outgoingSink?.finish()
                        return (index, .success)
                    } catch {
                        outgoingSink?.finish()
                        throw error
                    }
                }
            }

            // Collect every stage's status so pipefail can pick the
            // rightmost non-zero. Pre-fill with .success — stages
            // that are cancelled mid-stream (because a downstream
            // consumer finished) shouldn't count as failures.
            var stageStatuses = Array(repeating: ExitStatus.success,
                                      count: stages.count)
            var lastStageDone = false
            while true {
                do {
                    guard let (index, result) = try await group.next() else {
                        break
                    }
                    stageStatuses[index] = result
                    if index == stages.count - 1 {
                        lastStageDone = true
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
            _ = lastStageDone

            if pipefailMode {
                // Rightmost non-zero status, or .success if every
                // stage succeeded.
                for s in stageStatuses.reversed() where !s.isSuccess {
                    return s
                }
                return .success
            }
            return stageStatuses.last ?? .success
        }

        // `!`-prefixed pipelines disable errexit on the inverted
        // result (matching bash). Tell the enclosing executeList to
        // skip its next errexit check.
        if invert {
            let inverted: ExitStatus = status.isSuccess ? .failure : .success
            skipNextErrexitCheck = true
            lastExitStatus = inverted
            return inverted
        }
        lastExitStatus = status
        return status
    }
}
