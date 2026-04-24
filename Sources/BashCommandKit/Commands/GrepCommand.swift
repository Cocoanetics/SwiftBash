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

    public mutating func execute(shell: Shell) throws -> ExitStatus {
        if shell.stdin.isEmpty { return .failure }

        let needle = ignoreCase ? pattern.lowercased() : pattern
        var lines = shell.stdin.split(separator: "\n",
                                      omittingEmptySubsequences: false)
        // Input ending with `\n` leaves a bogus trailing empty element.
        if shell.stdin.hasSuffix("\n"), lines.last?.isEmpty == true {
            lines.removeLast()
        }

        var out = ""
        var matched = false
        for line in lines {
            let haystack = ignoreCase ? line.lowercased() : String(line)
            let contains = haystack.contains(needle)
            let keep = invert ? !contains : contains
            if keep {
                out.append(contentsOf: line)
                out.append("\n")
                matched = true
            }
        }
        shell.stdout(out)
        return matched ? .success : .failure
    }
}
