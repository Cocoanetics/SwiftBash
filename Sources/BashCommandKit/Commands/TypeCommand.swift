import ArgumentParser
import BashInterpreter

/// `type NAME...` — for each NAME, describe how the shell would
/// resolve it. We only have one resolution category (the registry),
/// so the output is `<name> is a shell builtin`.
///
/// Real bash distinguishes builtins / functions / aliases / files. We
/// don't have functions or aliases as separable categories yet, so
/// everything in the registry — kit commands and language built-ins
/// alike — reports as "shell builtin".
public struct TypeCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Describe how the shell would resolve a name."
    )

    @Argument(help: "Names to look up.")
    public var names: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        if names.isEmpty {
            Shell.current.stderr("type: missing operand\n")
            return .failure
        }
        var missing = false
        for name in names {
            if Shell.current.commands[name] != nil {
                Shell.current.stdout("\(name) is a shell builtin\n")
            } else {
                Shell.current.stderr("type: \(name): not found\n")
                missing = true
            }
        }
        return missing ? .failure : .success
    }
}
