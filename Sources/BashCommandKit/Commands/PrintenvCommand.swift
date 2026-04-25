import ArgumentParser
import BashInterpreter

/// `printenv [NAME...]` — print environment variables.
///
/// With no NAMEs: every variable, sorted, as `NAME=VALUE` per line
/// (same shape as ``EnvCommand``). With one NAME: print just its
/// value (no name prefix), exit 0; or exit 1 silently if unset. With
/// many NAMEs: print each defined value in argv order, exit 1 if any
/// were unset.
public struct PrintenvCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "printenv",
        abstract: "Print environment variables."
    )

    @Argument(help: "Variable names. Prints all variables if empty.")
    public var names: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        if names.isEmpty {
            for (k, v) in shell.environment.variables
                .sorted(by: { $0.key < $1.key }) {
                shell.stdout("\(k)=\(v)\n")
            }
            return .success
        }
        var missing = false
        for name in names {
            if let v = shell.environment[name] {
                shell.stdout(v + "\n")
            } else {
                missing = true
            }
        }
        return missing ? .failure : .success
    }
}
