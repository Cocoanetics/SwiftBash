import Foundation
import BashSyntax

extension Shell {

    /// Execute a `pipeline` node. Parts alternate between commands and
    /// `.pipe("|" | "|&")` separators, with an optional leading
    /// `.reservedWord("!")` that inverts the final exit status.
    ///
    /// Each stage runs in its own `Task` inside a `TaskGroup`, wired
    /// together by `AsyncStream<Data>` channels. Stage N writes chunks
    /// as it produces them; stage N+1 awaits the stream — so infinite
    /// producers like `tail -f` interleave with consumers like
    /// `grep` without buffering. Environment mutations inside a stage
    /// are local: each stage runs on a *subshell* cloned from the
    /// outer shell's env.
    ///
    /// Exit status is the final stage's (bash default; `pipefail` off).
    /// `!` inverts it.
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

        // Build the inter-stage channels. For N stages, we need N-1.
        var channels: [(AsyncStream<Data>,
                        AsyncStream<Data>.Continuation)] = []
        for _ in 0..<max(0, stages.count - 1) {
            channels.append(AsyncStream<Data>.makeStream())
        }

        // Snapshot for stages; stage 0 inherits the outer shell's stdin.
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
                let incomingChannel = isFirst ? nil : channels[index - 1].0
                let outgoingCont = isLast ? nil : channels[index].1
                let mergeStderrIntoOutgoing = !isLast && pipeOps[index] == "|&"

                group.addTask {
                    // Build a subshell for this stage: separate env so
                    // mutations don't leak or race; shared command
                    // registry; per-stage stdio wired to the channels.
                    let sub = Shell(
                        environment: envSnapshot,
                        stdout: Shell.defaultStdout, // overridden below
                        stderr: Shell.defaultStderr,
                        commands: commandRegistry
                    )
                    sub.currentSource = sourceSnapshot

                    // stdin: inherit outer for stage 0, otherwise await
                    // the upstream channel.
                    if let incoming = incomingChannel {
                        sub.stdin = InputSource(bytes: incoming)
                    } else {
                        sub.stdin = outerStdin
                    }

                    // stdout: either the final shell's sink, or the
                    // channel to the next stage.
                    if let cont = outgoingCont {
                        sub.stdout = { cont.yield($0) }
                    } else {
                        sub.stdout = outerStdout
                    }

                    // stderr: in `|&` we merge into the next stage; in
                    // plain `|` we pass straight through.
                    if mergeStderrIntoOutgoing, let cont = outgoingCont {
                        sub.stderr = { cont.yield($0) }
                    } else {
                        sub.stderr = outerStderr
                    }

                    do {
                        let result = try await sub.execute(stage)
                        // Close the outgoing channel so the downstream
                        // stage's iterator finishes.
                        outgoingCont?.finish()
                        return (index, result)
                    } catch {
                        outgoingCont?.finish()
                        throw error
                    }
                }
            }

            // Wait for stages to complete. When the final stage finishes,
            // cancel any still-running upstreams — that's how a fast
            // consumer like `head` terminates an infinite producer like
            // `tail -f`.
            var finalStatus = ExitStatus.success
            while true {
                do {
                    guard let (index, result) = try await group.next() else {
                        break
                    }
                    if index == stages.count - 1 {
                        finalStatus = result
                        group.cancelAll()
                    }
                } catch is CancellationError {
                    // Expected for any upstream stage after cancelAll; keep draining.
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
