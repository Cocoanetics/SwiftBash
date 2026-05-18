import ArgumentParser
import BashInterpreter

/// `which NAME...` — for each NAME, print where the shell would
/// resolve it in `$PATH`.
///
/// Output matches `/usr/bin/which`: only file-backed commands surface
/// (shell built-ins are ignored — `which cd` prints nothing). With
/// `-a`, prints every matching path in PATH order so callers can see
/// shadowing.
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
        let resolver = PathResolver(Shell.bashCurrent)
        var missing = false
        for name in names {
            let matches = await resolver.allMatches(forName: name)
            // Shell built-ins are deliberately ignored — real
            // `/usr/bin/which` doesn't know about bash internals.
            // Functions live in the bash registry too; same rule.
            if matches.isEmpty {
                missing = true
                continue
            }
            if all {
                for match in matches {
                    Shell.bashCurrent.stdout(pathFor(match) + "\n")
                }
            } else if let first = matches.first {
                Shell.bashCurrent.stdout(pathFor(first) + "\n")
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
