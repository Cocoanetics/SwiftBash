import Foundation

extension Shell {

    /// Run `source` with fresh `stdout` / `stderr` sinks, wait for the
    /// script to finish, and return the full captured text along with
    /// the exit status.
    ///
    /// The shell's previous `stdout` / `stderr` are restored on the
    /// way out, so this is safe to call from arbitrary contexts.
    ///
    /// If you want to consume output live rather than drain it at the
    /// end, replace `shell.stdout` with your own `OutputSink` and
    /// iterate `stdout.bytes` / `stdout.lines` in a separate Task
    /// before calling `run`.
    @discardableResult
    public func runCapturing(_ source: String) async throws -> CapturedRun {
        let outSink = OutputSink()
        let errSink = OutputSink()

        let savedOut = stdout
        let savedErr = stderr
        stdout = outSink
        stderr = errSink

        let status: ExitStatus
        do {
            status = try await run(source)
        } catch {
            stdout = savedOut
            stderr = savedErr
            outSink.finish()
            errSink.finish()
            throw error
        }

        stdout = savedOut
        stderr = savedErr
        outSink.finish()
        errSink.finish()

        async let outStr = outSink.readAllString()
        async let errStr = errSink.readAllString()
        return CapturedRun(
            exitStatus: status,
            stdout: await outStr,
            stderr: await errStr
        )
    }
}
