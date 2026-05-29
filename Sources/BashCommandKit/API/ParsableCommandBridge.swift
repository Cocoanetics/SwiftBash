import ArgumentParser
import BashInterpreter

/// Adapter that wraps a ``ParsableBashCommand`` type so it conforms
/// to ``BashInterpreter/Command``. Users typically install one via
/// ``Shell/install(_:)`` with the type metatype
/// (see `Shell+ParsableCommand.swift`); this struct is the glue.
struct ParsableCommandBridge<Parsed: ParsableBashCommand>: Command {
    let name: String

    func run(_ argv: [String]) async throws -> ExitStatus {
        // The `--version` banner, cancellation, `Sandbox.Denial`
        // redaction, and error/exit-code formatting are shared with
        // ``AsyncParsableCommandBridge`` via
        // ``ArgumentParserBridge/dispatch(_:name:argv:invoke:)``; this
        // bridge only supplies the `ParsableBashCommand`-specific parse
        // + `execute()`.
        try await ArgumentParserBridge.dispatch(
            Parsed.self, name: name, argv: argv
        ) { args in
            var parsed = try Parsed.parse(args)
            return try await parsed.execute()
        }
    }
}
