import ArgumentParser
import BashInterpreter

/// Adapter that wraps a ``ParsableBashCommand`` type so it conforms
/// to ``BashInterpreter/Command``. Users typically register via
/// ``BashInterpreter/Shell/register(_:)`` with the type metatype
/// (see `Shell+ParsableCommand.swift`); this struct is the glue.
struct ParsableCommandBridge<Parsed: ParsableBashCommand>: Command {
    let name: String

    func run(_ argv: [String]) async throws -> ExitStatus {
        // ArgumentParser expects argv without the command name.
        let args = Array(argv.dropFirst())
        // `--version` short-circuit. ArgumentParser only handles it
        // when the command's `configuration.version` is non-empty,
        // and our `ParsableBashCommand`s typically don't set one —
        // so a GNU-style `sed --version` ends up reported as
        // "unknown option" instead of printing a banner. Catch the
        // flag in the bridge and emit a generic in-process marker
        // when the command itself didn't override.
        if args.contains("--version") {
            let configured = Parsed.configuration.version
            let banner = configured.isEmpty
                ? "\(name) (swift-bash built-in)"
                : configured
            Shell.bashCurrent.stdout(banner + "\n")
            return .success
        }
        do {
            var parsed = try Parsed.parse(args)
            return try await parsed.execute()
        } catch is CancellationError {
            // Cooperative cancellation must propagate so the
            // dispatcher / process table records the job as cancelled.
            // ArgumentParser's `fullMessage(for:)` doesn't know what
            // CancellationError is and would render it as a stray
            // "Error: CancellationError()" usage diagnostic.
            throw CancellationError()
        } catch let denial as Sandbox.Denial {
            // ShellKit's `Sandbox.Denial` is a plain struct with `url`,
            // `reason`, and `suggestion` fields. Through ArgumentParser's
            // `fullMessage(for:)` it would land on `String(describing:)`
            // and dump every field — including `suggestion`, which is
            // the embedder's host sandbox root + the requested path.
            // For an iOS-app-as-sandbox embedder that means leaking
            // the full container path into a `gh issue list`-style
            // error. Render just the reason; the user already knows
            // which command they ran.
            Shell.bashCurrent.stderr("\(name): \(denial.reason)\n")
            return ExitStatus(1)
        } catch {
            // ArgumentParser uses the error type to convey both real
            // usage errors *and* clean non-error exits like `--help`.
            // Normalise: ask it for a formatted message and an exit
            // code, then route each to the right stream.
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
