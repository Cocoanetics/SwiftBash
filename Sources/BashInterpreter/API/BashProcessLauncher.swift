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
/// - ``Executable/path(_:)`` resolves only when the supplied path
///   matches the canonical bin location for the name in
///   ``ShellKit/BinCatalog`` (so `/bin/echo` and `/usr/bin/jq`
///   resolve, but `/tmp/echo` doesn't — that one would be running
///   *some* file on disk under a different command shape, not the
///   registered `echo`). Mirrors ``VirtualBinFileSystem``'s
///   synthesized-file rule on the bash side.
/// - A miss throws ``ProcessLaunchUnresolved`` — for SwiftBash that
///   means "command not found." Bash itself never composes through
///   ``ChainLauncher`` (no real-exec fall-through), so the error is
///   what reaches the caller.
///
/// Termination: a launched command that calls `exit N` (the bash
/// `exit` builtin throws an internal ``ShellExit`` to unwind the
/// interpreter) is caught here and converted to an
/// ``ExecutionRecord`` with `.exited(N)`. Without this catch, an
/// `exit` from a script-launched command would unwind the caller's
/// own task as an error rather than reporting a clean exit code —
/// that's wrong for subprocess-style callers (a SwiftScript /
/// SwiftJSCore bridge running `Subprocess.run(.name("exit-1"))`
/// expects an `ExecutionRecord` back, not a thrown error).
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

    // swiftlint:disable:next function_parameter_count - signature comes from the `ProcessLauncher` protocol
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
        case .name(let name):
            resolvedName = name
        case .path(let pathStr):
            // Path-based resolution is restricted to the canonical
            // bin paths registered with `BinCatalog` (`/bin/echo`,
            // `/usr/bin/jq`, `/usr/local/bin/rg`, …). Anything else
            // — `/tmp/echo`, a relative path, an absolute path
            // shadowing a builtin — falls through to "unresolved"
            // because dispatching it to the registered command would
            // change exact-path subprocess semantics.
            let basename = (pathStr as NSString).lastPathComponent
            guard let canonical = BinCatalog.knownPaths[basename],
                  canonical == pathStr
            else {
                throw ProcessLaunchUnresolved(executable: executable)
            }
            resolvedName = basename
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
        if let workingDirectory, !workingDirectory.isEmpty {
            subShell.environment.workingDirectory = workingDirectory
        }
        subShell.stdin = input
        subShell.stdout = output
        subShell.stderr = error

        let argv = [resolvedName] + arguments.values

        // `ExitCommand` (and any registered command that calls into
        // the same machinery) throws an internal `ShellExit` to
        // unwind the interpreter on `exit N`. The bash dispatcher
        // catches it at the top of `Shell.run`, but a launcher
        // consumer is calling beneath that — so a child `exit 1`
        // would otherwise unwind the caller's task as an error
        // instead of reporting a clean exit code. Translate it here
        // to the `.exited(N)` record the caller expects.
        let status: ExitStatus
        do {
            status = try await subShell.withCurrent {
                try await command.run(argv)
            }
        } catch let exit as ShellExit {
            status = exit.status
        }

        return ExecutionRecord(
            processIdentifier: Int64(parent.virtualPID),
            terminationStatus: TerminationStatus.exited(status.code))
    }
}
