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
        } catch {
            // ArgumentParser uses the error type to convey both real
            // usage errors *and* clean non-error exits like `--help`.
            // Normalise: ask it for a formatted message and an exit
            // code, then route each to the right stream.
            let message = Parsed.fullMessage(for: error)
            let code = Parsed.exitCode(for: error).rawValue

            if !message.isEmpty {
                if code == 0 {
                    Shell.current.stdout(message + "\n")
                } else {
                    Shell.current.stderr(message + "\n")
                }
            }
            return ExitStatus(code)
        }
    }
}
