import ArgumentParser
import BashInterpreter

/// `type NAME...` — for each NAME, describe how the shell would
/// resolve it. Output mirrors bash's own `type`:
///
/// - File-shadowed registered commands (`cat`, `ls`, `grep`, …)
///   report `<name> is /bin/<name>` (or `/usr/bin/<name>`).
/// - Pure shell built-ins (`cd`, `export`, `eval`, …) report
///   `<name> is a shell builtin`.
/// - Unknown names print `type: <name>: not found` to stderr and
///   the command exits non-zero.
///
/// Real bash also distinguishes functions, aliases, and keywords;
/// SwiftBash doesn't have separable function / alias categories
/// yet, so registry membership maps directly to one of the two
/// categories above based on whether the name has a binary shadow.
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
            Shell.bashCurrent.stderr("type: missing operand\n")
            return .failure
        }
        var missing = false
        for name in names {
            guard Shell.bashCurrent.commands[name] != nil else {
                Shell.bashCurrent.stderr("type: \(name): not found\n")
                missing = true
                continue
            }
            if let path = BinCatalog.knownPaths[name] {
                Shell.bashCurrent.stdout("\(name) is \(path)\n")
            } else {
                Shell.bashCurrent.stdout("\(name) is a shell builtin\n")
            }
        }
        return missing ? .failure : .success
    }
}
