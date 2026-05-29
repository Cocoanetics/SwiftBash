import ArgumentParser
import BashInterpreter

/// Shared dispatch core for SwiftBash's two ArgumentParser bridges —
/// ``ParsableCommandBridge`` (for ``ParsableBashCommand``) and
/// ``AsyncParsableCommandBridge`` (for plain `AsyncParsableCommand`,
/// the shape SwiftPorts CLIs use).
///
/// The two bridges differ only in *how* they parse and invoke the
/// command (`parse` + `execute()` vs `parseAsRoot` + `run()`).
/// Everything around that — the GNU-style `--version` banner,
/// cooperative-cancellation propagation, `Sandbox.Denial` redaction,
/// and ArgumentParser's message / exit-code formatting — is identical.
/// Keeping it here means the two bridges can't drift apart (a fix to
/// the Denial redaction or the error routing lands once, not twice).
enum ArgumentParserBridge {

    /// Run a parsed command through the shared bridge plumbing.
    ///
    /// - Parameters:
    ///   - type: the command metatype — used for `configuration.version`
    ///     and ArgumentParser's `fullMessage` / `exitCode` formatting.
    ///   - name: the registered command name (argv[0]) — used in the
    ///     `--version` banner and `Sandbox.Denial` diagnostics.
    ///   - argv: the full argv including argv[0] (the command name),
    ///     dropped before parsing per the `execve` convention.
    ///   - invoke: parses `args` (argv minus the command name) and runs
    ///     the resolved command, returning its ``ExitStatus``. Anything
    ///     it throws is funnelled through the shared `catch` ladder.
    static func dispatch<P: ParsableCommand>(
        _ type: P.Type,
        name: String,
        argv: [String],
        invoke: (_ args: [String]) async throws -> ExitStatus
    ) async throws -> ExitStatus {
        // ArgumentParser expects argv without the command name.
        let args = Array(argv.dropFirst())

        // `--version` short-circuit. ArgumentParser only handles it when
        // the command's `configuration.version` is non-empty, and our
        // commands often don't set one — so a GNU-style `sed --version`
        // would otherwise be reported as "unknown option" instead of a
        // banner. Catch the flag here and emit a generic in-process
        // banner when the command itself didn't override.
        //
        // Only the *leading* arg short-circuits. A laxer
        // `args.contains("--version")` would swallow the flag meant for
        // a different tool — `command find --version` would print
        // `command`'s banner instead of routing the flag to `find`.
        if args.first == "--version" {
            let configured = P.configuration.version
            let banner = configured.isEmpty
                ? "\(name) (SwiftBash) \(SwiftBashVersion.packageVersion)"
                : configured
            Shell.bashCurrent.stdout(banner + "\n")
            return .success
        }

        do {
            return try await invoke(args)
        } catch is CancellationError {
            // Cooperative cancellation must propagate so the dispatcher
            // / process table records the job as cancelled. ArgumentParser's
            // `fullMessage(for:)` doesn't know what CancellationError is
            // and would render it as a stray "Error: CancellationError()"
            // usage diagnostic.
            throw CancellationError()
        } catch let exitCode as ExitCode {
            // An explicit exit status with no accompanying message.
            return ExitStatus(exitCode.rawValue)
        } catch let denial as Sandbox.Denial {
            // ShellKit's `Sandbox.Denial` is a plain struct with `url`,
            // `reason`, and `suggestion` fields. Through ArgumentParser's
            // `fullMessage(for:)` it would land on `String(describing:)`
            // and dump every field — including `suggestion`, which is the
            // embedder's host sandbox root + the requested path. For an
            // iOS-app-as-sandbox embedder that leaks the full container
            // path into a `gh issue list`-style error. Render just the
            // reason; the user already knows which command they ran.
            Shell.bashCurrent.stderr("\(name): \(denial.reason)\n")
            return ExitStatus(1)
        } catch {
            // ArgumentParser uses the error type to convey both real
            // usage errors *and* clean non-error exits like `--help`.
            // Normalise: ask it for a formatted message and an exit code,
            // then route each to the right stream.
            let message = P.fullMessage(for: error)
            let code = P.exitCode(for: error).rawValue
            if !message.isEmpty {
                if code == 0 {
                    Shell.bashCurrent.stdout(message + "\n")
                } else {
                    Shell.bashCurrent.stderr(message + "\n")
                }
            }
            return ExitStatus(code)
        }
    }
}
