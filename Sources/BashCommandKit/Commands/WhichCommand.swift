import ArgumentParser
import BashInterpreter

/// `which NAME...` — for each NAME, print `/builtin/<name>` if a
/// command of that name is registered on the shell, else exit non-zero.
///
/// Differs from real `which` in that we have no `$PATH`-walking story
/// (yet). Every registered command lives in a synthetic `/builtin/`
/// namespace; that's what we print so output looks path-shaped.
///
/// Exit status: 0 if all NAMEs are registered, 1 otherwise (matching
/// `which`'s convention on Linux/macOS).
public struct WhichCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "which",
        abstract: "Locate a command in the shell's registry."
    )

    @Argument(help: "Command names to look up.")
    public var names: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        if names.isEmpty {
            Shell.current.stderr("which: missing operand\n")
            return .failure
        }
        var missing = false
        for name in names {
            if Shell.current.commands[name] != nil {
                Shell.current.stdout("/builtin/\(name)\n")
            } else {
                missing = true
            }
        }
        return missing ? .failure : .success
    }
}
