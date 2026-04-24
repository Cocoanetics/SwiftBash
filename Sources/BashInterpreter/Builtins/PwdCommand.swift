import Foundation

/// `pwd` — prints the shell's working directory.
public struct PwdCommand: Command {
    public let name = "pwd"
    public init() {}
    public func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
        shell.stdout(shell.environment.workingDirectory + "\n")
        return .success
    }
}
