import Foundation

/// A ``Command`` backed by a closure — the shortest path to adding a
/// custom command to a ``Shell`` without defining a new type.
///
/// ```swift
/// let greet = ClosureCommand(name: "greet") { argv, shell in
///     shell.stdout("hello \(argv.dropFirst().joined(separator: " "))\n")
///     return .success
/// }
/// shell.register(greet)
/// try shell.run("greet world")   // → hello world
/// ```
///
/// Prefer ``Shell/register(name:_:)`` for the common case; this struct is
/// useful when you want to build a command separately, pass it around,
/// or register the same body under multiple names.
public struct ClosureCommand: Command {
    public let name: String
    private let body: ([String], Shell) async throws -> ExitStatus

    public init(name: String,
                body: @escaping ([String], Shell) async throws -> ExitStatus) {
        self.name = name
        self.body = body
    }

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        try await body(argv, shell)
    }
}
