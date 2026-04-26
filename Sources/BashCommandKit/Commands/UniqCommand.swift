import ArgumentParser
import BashInterpreter
import Foundation

/// `uniq [-c] [INPUT [OUTPUT]]` — collapse runs of *adjacent* equal
/// lines.
///
/// With no INPUT, reads stdin. Note: `uniq` only deduplicates adjacent
/// lines — pre-sort with `sort -u` (or `sort | uniq`) for global
/// deduplication.
///
/// Supported flags:
/// - `-c` / `--count` — prefix each output line with its repeat count
///
/// Skipped (low usage in the call-frequency report): `-d`, `-u`, `-i`,
/// `-f N`, `-s N`, OUTPUT positional.
public struct UniqCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "uniq",
        abstract: "Filter adjacent duplicate lines."
    )

    @Argument(help: "Input file. Reads stdin if empty.")
    public var input: String?

    @Flag(name: [.customShort("c"), .customLong("count")],
          help: "Prefix each line with its repeat count.")
    public var count: Bool = false

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var lines: [String] = []
        if let f = input {
            do {
                let data = try await Shell.current.readDataAtPath(f)
                let text = String(decoding: data, as: UTF8.self)
                lines = SortCommand.splitLines(text)
            } catch {
                Shell.current.stderr("uniq: \(f): \(error)\n")
                return .failure
            }
        } else {
            for await line in Shell.current.stdin.lines { lines.append(line) }
        }

        var i = 0
        while i < lines.count {
            var run = 1
            while i + run < lines.count, lines[i + run] == lines[i] {
                run += 1
            }
            if count {
                // Match BSD `uniq -c`: 4-char right-aligned count, one
                // space, then the line.
                Shell.current.stdout(String(format: "%4d %@\n",
                                    run, lines[i] as NSString))
            } else {
                Shell.current.stdout(lines[i] + "\n")
            }
            i += run
        }
        return .success
    }
}
