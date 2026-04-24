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

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        for (k, v) in shell.environment.variables.sorted(by: { $0.key < $1.key }) {
            shell.stdout("\(k)=\(v)\n")
        }
        return .success
    }
}
