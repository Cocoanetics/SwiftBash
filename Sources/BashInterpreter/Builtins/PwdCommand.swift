import Foundation

/// `pwd` — prints the shell's working directory.
public struct PwdCommand: Command {
    public let name = "pwd"
    public init() {}
    public func run(_ argv: [String]) async throws -> ExitStatus {
        Shell.current.stdout(Shell.current.environment.workingDirectory + "\n")
        return .success
    }
}
