import Foundation

/// `false` — always exits with status 1.
public struct FalseCommand: Command {
    public let name = "false"
    public init() {}
    public func run(_ argv: [String]) async throws -> ExitStatus {
        .failure
    }
}
