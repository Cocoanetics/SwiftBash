import Foundation
import ShellKit

/// `ProcessLauncher` that resolves an executable against this shell's
/// command registry and runs the matching ``Command`` in a subshell
/// with the supplied environment / cwd / stdio overrides applied.
///
/// SwiftBash is a pure-Swift, sandbox-by-default interpreter — there
/// is no `posix_spawn` / `fork` path. Every "process" is a registered
/// Swift command. This launcher is the door through which any
/// `ShellKit.Shell.current.processLauncher` consumer reaches that
/// registry: a SwiftScript script going through its `Subprocess`
/// bridge, a SwiftJSCore script going through `child_process.spawn`,
/// any future runtime — all converge on the same `commands[…]` table
/// when bound to a SwiftBash `Shell`.
///
/// Resolution rules:
/// - ``Executable/name(_:)`` is looked up by the supplied name as-is.
/// - ``Executable/path(_:)`` is resolved by basename (so
///   `/usr/bin/echo` finds the registered `echo`); SwiftBash's
///   virtual `/bin` and `/usr/bin` already make these paths point at
///   the registry from the bash side, and this matches that view from
///   the launcher side.
/// - A miss throws ``ProcessLaunchUnresolved`` — for SwiftBash that
///   means "command not found." Bash itself never composes through
///   ``ChainLauncher`` (no real-exec fall-through), so the error is
///   what reaches the caller.
///
/// Stdio: the launcher swaps the subshell's `stdin` / `stdout` /
/// `stderr` to the caller-supplied sinks before running the command,
/// so anything the command writes to ``Shell/stdout`` is streamed
/// straight to the caller. The returned ``ExecutionRecord`` carries
/// empty `standardOutput` / `standardError` buffers — consumers that
/// want a buffered copy (SwiftScript's `Output.string(limit:)`
/// adapter) supply a buffering ``OutputSink`` and read it after
/// ``launch(_:arguments:environment:workingDirectory:input:output:error:)``
/// returns.
public struct BashProcessLauncher: ProcessLauncher {

    public init() {}

    public func launch(
        _ executable: Executable,
        arguments: Arguments,
        environment: Environment,
        workingDirectory: String?,
        input: InputSource,
        output: OutputSink,
        error: OutputSink
    ) async throws -> ExecutionRecord {
        // Read the bash-typed TaskLocal — the launcher's caller is
        // expected to be running inside a `Shell.bashCurrent.withCurrent`
        // binding (the SwiftScript / SwiftJSCore bridges run their
        // script bodies that way). Falls back to the default shell
        // outside that context, in which case the registry is empty
        // and resolution misses cleanly.
        let parent = Shell.bashCurrent

        let resolvedName: String
        switch executable.storage {
        case .name(let n):
            resolvedName = n
        case .path(let p):
            resolvedName = (p as NSString).lastPathComponent
        }

        guard let command = parent.commands[resolvedName] else {
            throw ProcessLaunchUnresolved(executable: executable)
        }

        // Subshell for the run. `copy()` already inherits everything
        // inheritable (including the parent's `processLauncher`, so a
        // command that re-enters this launcher recursively keeps
        // resolving against the same registry).
        let subShell = parent.copy()
        subShell.environment = environment
        if let wd = workingDirectory, !wd.isEmpty {
            subShell.environment.workingDirectory = wd
        }
        subShell.stdin = input
        subShell.stdout = output
        subShell.stderr = error

        let argv = [resolvedName] + arguments.values

        let status: ExitStatus = try await subShell.withCurrent {
            try await command.run(argv)
        }

        return ExecutionRecord(
            processIdentifier: Int64(parent.virtualPID),
            terminationStatus: TerminationStatus.exited(status.code))
    }
}
