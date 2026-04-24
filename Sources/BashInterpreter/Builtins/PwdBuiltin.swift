import Foundation

/// `pwd` — prints the shell's working directory.
public struct PwdBuiltin: Builtin {
    public let name = "pwd"
    public init() {}
    public func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
        shell.stdout(shell.environment.workingDirectory + "\n")
        return .success
    }
}
