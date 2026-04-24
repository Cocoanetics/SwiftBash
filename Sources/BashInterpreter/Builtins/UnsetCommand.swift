import Foundation

/// `unset NAME...` — removes each named variable from the shell's env.
public struct UnsetCommand: Command {
    public let name = "unset"
    public init() {}

    public func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
        for name in argv.dropFirst() {
            shell.environment.variables.removeValue(forKey: name)
        }
        return .success
    }
}
