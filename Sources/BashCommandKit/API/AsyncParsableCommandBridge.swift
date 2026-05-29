import ArgumentParser
import BashInterpreter

/// Adapter that wraps an ``AsyncParsableCommand`` type (the shape
/// SwiftPorts CLIs — `Jq`, `Rg`, `GhCommand`, `TarCommand`, the
/// compression family — use) so it conforms to
/// ``BashInterpreter/Command``. Users typically install one via
/// ``Shell/install(_:)`` with the type metatype
/// (see `Shell+ParsableCommand.swift`); this struct is the glue.
struct AsyncParsableCommandBridge<Parsed: AsyncParsableCommand>: Command {
    let name: String

    func run(_ argv: [String]) async throws -> ExitStatus {
        // The `--version` banner, cancellation, `Sandbox.Denial`
        // redaction, and error/exit-code formatting are shared with
        // ``ParsableCommandBridge`` via
        // ``ArgumentParserBridge/dispatch(_:name:argv:invoke:)``; this
        // bridge only supplies the `AsyncParsableCommand`-specific parse
        // + dispatch.
        try await ArgumentParserBridge.dispatch(
            Parsed.self, name: name, argv: argv
        ) { args in
            var parsed = try Parsed.parseAsRoot(args)
            // `parseAsRoot` resolves a subcommand to its concrete type
            // (so `gh issue list` ends up as `IssueList` rather than
            // `GhCommand`). The resolved value is either Async or sync
            // ParsableCommand; dispatch through whichever surface is
            // available without forcing every leaf to be async.
            if var async = parsed as? AsyncParsableCommand {
                try await async.run()
            } else {
                try parsed.run()
            }
            return .success
        }
    }
}
