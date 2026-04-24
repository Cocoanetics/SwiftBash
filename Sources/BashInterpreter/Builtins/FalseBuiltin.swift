import Foundation

/// `false` — always exits with status 1.
public struct FalseBuiltin: Builtin {
    public let name = "false"
    public init() {}
    public func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
        .failure
    }
}
