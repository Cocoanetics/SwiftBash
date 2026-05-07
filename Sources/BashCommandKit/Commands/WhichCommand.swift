import ArgumentParser
import BashInterpreter

/// `which NAME...` — for each NAME, print where the shell would
/// resolve it.
///
/// Output format mirrors what a real macOS install reports:
/// - For a registered command that has a binary shadow path
///   (`cat`, `ls`, `grep`, …) — print the full `/bin/<name>` or
///   `/usr/bin/<name>` path, the same string `ls /bin` would show.
/// - For a registered command that's a pure shell built-in (`cd`,
///   `export`, `eval`, `declare`, …) — print
///   `<name>: shell built-in command`.
/// - For an unknown name — print nothing and contribute a non-zero
///   exit, matching `/usr/bin/which` semantics.
///
/// Exit status: 0 if every NAME resolved, 1 otherwise.
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
            Shell.bashCurrent.stderr("which: missing operand\n")
            return .failure
        }
        var missing = false
        for name in names {
            guard Shell.bashCurrent.commands[name] != nil else {
                missing = true
                continue
            }
            if let path = BinCatalog.knownPaths[name] {
                Shell.bashCurrent.stdout("\(path)\n")
            } else {
                Shell.bashCurrent.stdout("\(name): shell built-in command\n")
            }
        }
        return missing ? .failure : .success
    }
}
