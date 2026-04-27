import ArgumentParser
import BashInterpreter

/// `command -v NAME...` — print the resolved name (just NAME in our
/// world; we don't have $PATH paths) if registered, else exit non-zero
/// with no output. This is the bash idiom for "is X available?":
///
/// ```bash
/// if command -v jq >/dev/null; then …
/// ```
///
/// Out of scope: `command -p` (default-PATH bypass), `command -V`
/// (verbose), bypassing functions/aliases — we don't have separable
/// resolution categories.
public struct CommandBuiltinCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "command",
        abstract: "Locate a command, or run one bypassing functions."
    )

    @Flag(name: .customShort("v"),
          help: "Print the command name(s) that would be invoked.")
    public var lookup: Bool = false

    @Argument(help: "Names to look up (or, without -v, a command to run).")
    public var names: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard !names.isEmpty else {
            Shell.current.stderr("command: missing operand\n")
            return .failure
        }
        if lookup {
            var missing = false
            for name in names {
                guard Shell.current.commands[name] != nil else {
                    missing = true
                    continue
                }
                // bash `command -v` prints the resolved path for
                // file-shadowed commands and just the name for
                // built-ins, exactly matching `which` shape.
                if let path = BinCatalog.knownPaths[name] {
                    Shell.current.stdout("\(path)\n")
                } else {
                    Shell.current.stdout("\(name)\n")
                }
            }
            return missing ? .failure : .success
        }
        // Without -v: re-dispatch as a normal invocation. We have no
        // functions/aliases yet, so this reduces to "look up in the
        // registry and call". Same shape as Shell's own dispatch.
        let head = names[0]
        guard let cmd = Shell.current.commands[head] else {
            Shell.current.stderr("command: \(head): not found\n")
            return ExitStatus(127)
        }
        return try await cmd.run(names)
    }
}
