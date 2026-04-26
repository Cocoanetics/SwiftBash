import Foundation
import BashSyntax

/// A user-defined function — `name() { … }` or `function name { … }`.
///
/// When invoked it sets up a function-call frame (positional params
/// from `argv[1...]`, a local-variable frame, and an incremented
/// ``Shell/functionCallDepth``), runs the body, and tears down the
/// frame again. `return N` from inside the body unwinds via
/// ``ReturnSignal``.
struct FunctionCommand: Command {
    let name: String
    let body: Node
    /// The source text active when the function was defined — the
    /// function might be called from a different `run` invocation
    /// where `currentSource` has changed, so we hold our own copy
    /// for word expansion of the body.
    let definitionSource: String

    func run(_ argv: [String]) async throws -> ExitStatus {
        // Save call-frame state.
        let savedParams = Shell.current.positionalParameters
        let savedSource = Shell.current.currentSource

        Shell.current.positionalParameters = Array(argv.dropFirst())
        Shell.current.currentSource = definitionSource
        Shell.current.functionCallDepth += 1
        Shell.current.localVarStack.append([])

        defer {
            // Pop locals — restore shadowed values in reverse order.
            if let frame = Shell.current.localVarStack.popLast() {
                for (name, prior) in frame.reversed() {
                    Shell.current.environment[name] = prior
                }
            }
            Shell.current.functionCallDepth -= 1
            Shell.current.positionalParameters = savedParams
            Shell.current.currentSource = savedSource
        }

        do {
            let result = try await Shell.current.execute(body)
            Shell.current.lastExitStatus = result
            return result
        } catch let ret as ReturnSignal {
            Shell.current.lastExitStatus = ret.status
            return ret.status
        }
    }
}

/// Thrown by the `return` builtin; caught by ``FunctionCommand``.
struct ReturnSignal: Error {
    let status: ExitStatus
}
