import ArgumentParser
import BashInterpreter

/// Adapter that wraps a ``ParsableBashCommand`` type so it conforms to
/// ``BashInterpreter/Command``. Users typically register via
/// ``BashInterpreter/Shell/register(_:)`` with the type metatype
/// (see `Shell+ParsableCommand.swift`); this struct is the glue.
struct ParsableCommandBridge<Parsed: ParsableBashCommand>: Command {
    let name: String

    func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
        // ArgumentParser expects argv without the command name.
        let args = Array(argv.dropFirst())
        do {
            var parsed = try Parsed.parse(args)
            return try parsed.execute(shell: shell)
        } catch {
            // ArgumentParser uses the error type to convey both real
            // usage errors *and* clean non-error exits like `--help`. We
            // normalise by asking it for a formatted message and an exit
            // code, then route each to the right stream.
            let message = Parsed.fullMessage(for: error)
            let code = Parsed.exitCode(for: error).rawValue

            if !message.isEmpty {
                if code == 0 {
                    shell.stdout(message + "\n")
                } else {
                    shell.stderr(message + "\n")
                }
            }
            return ExitStatus(code)
        }
    }
}
