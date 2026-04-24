import Foundation

/// `true` — always exits with status 0.
public struct TrueCommand: Command {
    public let name = "true"
    public init() {}
    public func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
        .success
    }
}
