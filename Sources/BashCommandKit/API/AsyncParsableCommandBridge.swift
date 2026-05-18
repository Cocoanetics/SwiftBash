import ArgumentParser
import BashInterpreter

/// Adapter that wraps an ``AsyncParsableCommand`` type (the shape
/// SwiftPorts CLIs — `Jq`, `Rg`, `GhCommand`, `TarCommand`, the
/// compression family — use) so it conforms to
/// ``BashInterpreter/Command``. Users typically install via
/// ``BashInterpreter/Shell/install(_:)-<…>`` with the type metatype
/// (see `Shell+ParsableCommand.swift`); this struct is the glue.
struct AsyncParsableCommandBridge<Parsed: AsyncParsableCommand>: Command {
    let name: String

    func run(_ argv: [String]) async throws -> ExitStatus {
        // ArgumentParser expects argv without the command name.
        let args = Array(argv.dropFirst())
        // `--version` short-circuit, mirroring ``ParsableCommandBridge``.
        if args.first == "--version" {
            let configured = Parsed.configuration.version
            let banner = configured.isEmpty
                ? "\(name) (SwiftBash) \(SwiftBashVersion.packageVersion)"
                : configured
            Shell.bashCurrent.stdout(banner + "\n")
            return .success
        }
        do {
            var parsed = try Parsed.parseAsRoot(args)
            // `parseAsRoot` resolves a subcommand to its concrete type
            // (so `gh issue list` ends up as `IssueList` rather than
            // `GhCommand`). The resolved value is either Async or sync
            // ParsableCommand; we dispatch through whichever surface
            // is available without forcing every leaf to be async.
            if var async = parsed as? AsyncParsableCommand {
                try await async.run()
            } else {
                try parsed.run()
            }
            return .success
        } catch let exitCode as ExitCode {
            return ExitStatus(exitCode.rawValue)
        } catch is CancellationError {
            // Cooperative cancellation must propagate so the dispatcher
            // / process table records the job as cancelled.
            throw CancellationError()
        } catch let denial as Sandbox.Denial {
            // Same redaction logic as ``ParsableCommandBridge``: keep
            // the embedder's host-side suggestion out of script
            // diagnostics.
            Shell.bashCurrent.stderr("\(name): \(denial.reason)\n")
            return ExitStatus(1)
        } catch {
            // ArgumentParser uses the error type to convey real usage
            // errors and clean non-error exits like `--help`. Format
            // through the parser, route to stdout/stderr by exit code.
            let message = Parsed.fullMessage(for: error)
            let code = Parsed.exitCode(for: error).rawValue

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
