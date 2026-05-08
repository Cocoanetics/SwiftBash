import BashInterpreter
import SwiftScriptInterpreter

/// SwiftBash's ``ScriptInterpreter`` adapter for SwiftScript.
///
/// Because SwiftScript reads its IO / FS / network / identity / exit
/// through `ShellKit.Shell.current` — the same TaskLocal SwiftBash
/// binds at every dispatch — the bridge collapses to construction +
/// `evalScript(_:fileName:)`. Output / stderr / stdin / sandbox /
/// identity all flow correctly without per-call wiring.
///
/// One fresh `Interpreter` per script: SwiftScript's interpreter
/// holds extensive mutable state (declared types, scopes, bridges)
/// that we don't want leaking between script invocations.
public struct SwiftScriptShellInterpreter: ScriptInterpreter {
    public let name: String

    /// Default registration name — `swift-script`. The CLI binary
    /// shipped by the SwiftScript package is named `swift-script`,
    /// and a script written for it is conventionally launched via
    /// `#!/usr/bin/env swift-script`. ``Shell/registerSwiftScript(names:)``
    /// also registers under the bare `swift` shebang by default.
    public init(name: String = "swift-script") {
        self.name = name
    }

    public func run(
        _ context: ScriptInterpreterContext
    ) async throws -> ExitStatus {
        let interpreter = Interpreter()
        do {
            return try await interpreter.evalScript(
                context.source, fileName: context.scriptPath)
        } catch let parseError as ParseError {
            // Render the diagnostic via the interpreter's `error`
            // closure (defaults to `Shell.current.stderr`) so it
            // captures alongside script-side stderr writes.
            interpreter.error(parseError.formatted)
            if !parseError.formatted.hasSuffix("\n") {
                interpreter.error("\n")
            }
            return ExitStatus(1)
        } catch is CancellationError {
            // Cooperative cancellation propagated from the parent
            // shell (e.g. `kill` against a backgrounded script) —
            // bash convention: 128 + SIGTERM = 143.
            return ExitStatus(143)
        } catch {
            interpreter.error(interpreter.renderRuntimeError(error))
            return ExitStatus(1)
        }
    }
}
