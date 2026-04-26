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

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        let args = argv.dropFirst()
        if args.isEmpty { return .success }
        let source = args.joined(separator: " ")

        let savedSource = shell.currentSource
        defer { shell.currentSource = savedSource }
        return try await shell.run(source)
    }
}
