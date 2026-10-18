import Foundation
import BashSyntax

/// `eval [ARG…]` — concatenate ARGs with spaces and execute the result
/// as bash code in the *current* shell. Variables, functions, and
/// directory state set by the eval'd code persist.
///
/// Mirrors `source`'s in-shell execution but without reading a file or
/// rebinding positional parameters. `return N` propagates back through
/// `eval` only when called inside a function (POSIX-aligned).
public struct EvalCommand: Command {
    public let name = "eval"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = argv.dropFirst()
        if args.isEmpty { return .success }
        let source = args.joined(separator: " ")

        let savedSource = Shell.bashCurrent.currentSource
        // The eval'd text continues the caller's line count (`$LINENO`).
        let savedLineOffset = Shell.bashCurrent.dynamicVariables.lineOffset
        Shell.bashCurrent.dynamicVariables.lineOffset =
            Shell.bashCurrent.currentLineNumber - 1
        defer {
            Shell.bashCurrent.currentSource = savedSource
            Shell.bashCurrent.dynamicVariables.lineOffset = savedLineOffset
        }
        return try await Shell.bashCurrent.run(source)
    }
}
