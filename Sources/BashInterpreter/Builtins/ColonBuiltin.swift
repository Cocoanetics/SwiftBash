import Foundation

/// `:` — the null command. Evaluates its arguments (word expansion runs
/// before the built-in is invoked) and exits with status 0.
public struct ColonBuiltin: Builtin {
    public let name = ":"
    public init() {}
    public func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
        .success
    }
}
