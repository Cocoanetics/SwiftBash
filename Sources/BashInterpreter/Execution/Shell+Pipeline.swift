import Foundation
import BashSyntax

extension Shell {

    /// Execute a `pipeline` node. Parts alternate between commands and
    /// `.pipe("|" | "|&")` separators, with an optional leading
    /// `.reservedWord("!")` that inverts the final exit status.
    ///
    /// Pipelines are executed **sequentially with buffered stdio** in
    /// this skeleton — stage N runs to completion, its stdout (and
    /// stderr, for `|&`) are captured into a String, and stage N+1 then
    /// runs with that String as its `stdin`. True concurrent
    /// `pipe(2)`-backed pipelines come with subprocess support.
    ///
    /// Consequences vs. bash:
    /// - Early termination of the reader (`yes | head`) doesn't stop
    ///   the writer; the writer runs fully before `head` sees anything.
    /// - Variables assigned inside a pipeline stage DO persist in the
    ///   shell (real bash runs each stage in its own subshell).
    /// - Exit status is the final stage's — bash-default `pipefail` off.
    func executePipeline(parts: [Node]) throws -> ExitStatus {
        var i = 0
        var invert = false
        if !parts.isEmpty,
           case .reservedWord(let w) = parts[0].kind, w == "!"
        {
            invert = true
            i = 1
        }

        // Separate command stages from the `|` / `|&` operators between them.
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

        let savedStdin = stdin
        let savedStdout = stdout
        let savedStderr = stderr
        defer {
            stdin = savedStdin
            stdout = savedStdout
            stderr = savedStderr
        }

        var currentInput = savedStdin
        var lastStatus = ExitStatus.success

        for (index, stage) in stages.enumerated() {
            let isLast = (index == stages.count - 1)
            stdin = currentInput

            if isLast {
                // The last stage writes directly to the shell's real
                // stdio — no capture.
                stdout = savedStdout
                stderr = savedStderr
                lastStatus = try execute(stage)
            } else {
                var buffer = ""
                stdout = { buffer.append($0) }

                // `|&` on the operator AFTER this stage merges its stderr
                // into the next stage's stdin.
                let mergeStderr = pipeOps[index] == "|&"
                if mergeStderr {
                    stderr = { buffer.append($0) }
                } else {
                    stderr = savedStderr
                }

                lastStatus = try execute(stage)
                currentInput = buffer
            }
        }

        lastExitStatus = invert
            ? (lastStatus.isSuccess ? .failure : .success)
            : lastStatus
        return lastExitStatus
    }
}
