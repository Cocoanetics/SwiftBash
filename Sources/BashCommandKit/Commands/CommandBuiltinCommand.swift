import ArgumentParser
import BashInterpreter
import Foundation

/// `command -v NAME...` — print the resolved name (or path, for
/// file-backed commands) if registered, else exit non-zero with no
/// output. Bash idiom for "is X available?":
///
/// ```bash
/// if command -v jq >/dev/null; then …
/// ```
///
/// Without `-v`: re-dispatches as a normal invocation, bypassing
/// shell functions / aliases (this implementation doesn't have a
/// separable function bucket from PATH yet, so it just runs the
/// shell built-in if available else the first `$PATH` hit).
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
            Shell.bashCurrent.stderr("command: missing operand\n")
            return .failure
        }
        let shell = Shell.bashCurrent
        if lookup {
            return await lookupNames(in: shell)
        }
        return try await runHead(in: shell)
    }

    private func lookupNames(in shell: Shell) async -> ExitStatus {
        let resolver = PathResolver(shell)
        var missing = false
        for name in names {
            if shell.shellBuiltins[name] != nil {
                // Built-in: print just the name (bash convention).
                shell.stdout("\(name)\n")
                continue
            }
            let first = await resolver.allMatches(forName: name).first
            switch first {
            case .registered(_, let path), .externalScript(let path):
                shell.stdout("\(path)\n")
            case .notFound, .none:
                missing = true
            }
        }
        return missing ? .failure : .success
    }

    private func runHead(in shell: Shell) async throws -> ExitStatus {
        // Without -v: re-dispatch the head as a command, bypassing
        // functions/aliases. Reach for built-ins first, then PATH.
        let head = names[0]
        if let builtin = shell.shellBuiltins[head] {
            return try await builtin.run(names)
        }
        switch await PathResolver(shell).resolve(head) {
        case .registered(let cmd, let path):
            var argv = names
            argv[0] = (path as NSString).lastPathComponent
            return try await cmd.run(argv)
        case .externalScript, .notFound:
            shell.stderr("command: \(head): not found\n")
            return ExitStatus(127)
        }
    }
}
