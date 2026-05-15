import ArgumentParser
import BashInterpreter

/// `env` — print the shell's environment, one `NAME=VALUE` per line,
/// sorted by name for reproducibility.
///
/// This is the shell-level `env`; it reflects the interpreter's
/// `Environment.variables` rather than the host process environment.
public struct EnvCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Print the shell environment."
    )

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        for (key, value) in Shell.bashCurrent.environment.variables.sorted(by: { $0.key < $1.key }) {
            Shell.bashCurrent.stdout("\(key)=\(value)\n")
        }
        return .success
    }
}
