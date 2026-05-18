import ArgumentParser
import BashInterpreter

/// `which NAME...` — for each NAME, print where the shell would
/// resolve it.
///
/// Output:
/// - File-backed match in `$PATH` → the absolute path.
/// - Pure shell built-in (no file at any `$PATH` entry) →
///   `<name>: shell built-in command`.
/// - Unknown name → nothing printed, contributes a non-zero exit.
///
/// With `-a`, every PATH hit is printed in order so callers can see
/// shadowing. A pure built-in's "shell built-in command" line is
/// printed alongside the (empty) PATH hits.
///
/// Exit status: 0 if every NAME resolved, 1 otherwise.
public struct WhichCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "which",
        abstract: "Locate a command in PATH."
    )

    @Flag(name: .customShort("a"),
          help: "Print every match in PATH order, not just the first.")
    public var all: Bool = false

    @Argument(help: "Command names to look up.")
    public var names: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        if names.isEmpty {
            Shell.bashCurrent.stderr("which: missing operand\n")
            return .failure
        }
        let shell = Shell.bashCurrent
        let resolver = PathResolver(shell)
        var missing = false
        for name in names {
            let matches = await resolver.allMatches(forName: name)
            if matches.isEmpty {
                if shell.shellBuiltins[name] != nil {
                    // Pure shell built-in: no file shadow anywhere
                    // in $PATH. Emit the SwiftBash convention so
                    // scripts probing `which` can tell built-ins
                    // from "not found."
                    shell.stdout("\(name): shell built-in command\n")
                    continue
                }
                missing = true
                continue
            }
            if all {
                for match in matches {
                    shell.stdout(pathFor(match) + "\n")
                }
            } else if let first = matches.first {
                shell.stdout(pathFor(first) + "\n")
            }
        }
        return missing ? .failure : .success
    }

    private func pathFor(_ resolution: PathResolver.Resolution) -> String {
        switch resolution {
        case .registered(_, let path): return path
        case .externalScript(let path): return path
        case .notFound: return ""
        }
    }
}
