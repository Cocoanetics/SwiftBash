import Foundation

extension Shell {

    /// Execute `source` as if it were a separate bash process
    /// invocation. State changes a script makes while it runs
    /// (working directory, exported variables, traps, `set -e`
    /// flags, `shopt`, function definitions, positional parameters)
    /// land on a fresh subshell created via ``copy()`` and **do not**
    /// propagate back to `self`. The next ``runIsolated(_:)`` call
    /// therefore starts from the same baseline as the first.
    ///
    /// Use this when each call is a distinct invocation from the
    /// embedder's point of view — for example, an LLM-agent `bash`
    /// tool where one tool call's `cd /tmp` or `trap … EXIT` must
    /// not leak into the next. The contract matches `bash -c '…'`:
    /// each invocation is its own shell.
    ///
    /// Contrast with ``run(_:)``, which mutates this shell so
    /// `cd`/`export`/`trap` accumulate across calls — the right
    /// choice for REPL-style embedders and for `eval` / `source` /
    /// `.profile` loading paths where state propagation is the
    /// whole point.
    ///
    /// Side effects that aren't shell-local state still propagate
    /// because they travel through references the subshell shares
    /// with `self`: filesystem writes (same ``fileSystem``),
    /// background jobs (same ``processTable``), output (same
    /// ``stdout`` / ``stderr`` sinks). A script that writes a file
    /// and registers a trap that touches that file will still see
    /// the write — only the in-memory trap registration and env
    /// vars are confined.
    @discardableResult
    public func runIsolated(_ source: String) async throws -> ExitStatus {
        return try await copy().run(source)
    }

    /// Capturing variant of ``runIsolated(_:)``. Runs `source` in
    /// a fresh ``copy()`` of this shell with private `stdout` /
    /// `stderr` sinks, waits for the script to finish, and returns
    /// the captured text plus the exit status. The parent shell's
    /// stdio is untouched and no state changes leak back.
    @discardableResult
    public func runCapturingIsolated(_ source: String) async throws -> CapturedRun {
        return try await copy().runCapturing(source)
    }
}
