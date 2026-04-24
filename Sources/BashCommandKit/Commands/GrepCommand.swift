import ArgumentParser
import BashInterpreter

/// `grep [-v] [-i] PATTERN` — print lines of stdin containing `PATTERN`.
///
/// This is a simplified grep: `PATTERN` is a plain substring (not a
/// regex). Exit status matches grep's convention: `.success` when at
/// least one line matched, `.failure` otherwise.
public struct GrepCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "grep",
        abstract: "Print lines of stdin that contain a substring."
    )

    @Argument(help: "Pattern (substring) to match.")
    public var pattern: String

    @Flag(name: [.customShort("v"), .customLong("invert-match")],
          help: "Print non-matching lines instead.")
    public var invert: Bool = false

    @Flag(name: [.customShort("i"), .customLong("ignore-case")],
          help: "Case-insensitive matching.")
    public var ignoreCase: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        let needle = ignoreCase ? pattern.lowercased() : pattern
        var matched = false

        // Stream line-by-line so we can match and print as data arrives
        // — essential for `tail -f | grep` style live pipelines.
        for await line in shell.stdin.lines {
            let haystack = ignoreCase ? line.lowercased() : line
            let contains = haystack.contains(needle)
            let keep = invert ? !contains : contains
            if keep {
                shell.stdout(line + "\n")
                matched = true
            }
        }
        return matched ? .success : .failure
    }
}
