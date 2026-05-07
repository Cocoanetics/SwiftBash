import ArgumentParser
import BashInterpreter
import Foundation

/// `comm [-1] [-2] [-3] FILE1 FILE2` — three-column compare of two
/// **sorted** files.
///
/// - Column 1 — lines only in FILE1
/// - Column 2 — lines only in FILE2 (preceded by 1 tab)
/// - Column 3 — lines in both (preceded by 2 tabs)
///
/// Suppress columns with `-1`, `-2`, `-3` (any combination). Both files
/// must be lexicographically sorted; comm doesn't sort, mismatches in
/// sort order produce wrong output.
///
/// Use `-` for either FILE to read from stdin (only once).
public struct CommCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "comm",
        abstract: "Compare two sorted files line by line."
    )

    @Flag(name: .customShort("1"),
          help: "Suppress column 1 (lines only in FILE1).")
    public var suppress1: Bool = false

    @Flag(name: .customShort("2"),
          help: "Suppress column 2 (lines only in FILE2).")
    public var suppress2: Bool = false

    @Flag(name: .customShort("3"),
          help: "Suppress column 3 (lines common to both).")
    public var suppress3: Bool = false

    @Argument(help: "Two input files (use `-` for stdin, at most once).")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        guard files.count == 2 else {
            Shell.bashCurrent.stderr("comm: expected two file arguments\n")
            return ExitStatus(2)
        }
        let lines: [[String]]
        do {
            lines = try await Self.readBoth(files: files)
        } catch let err as CommError {
            Shell.bashCurrent.stderr("comm: \(err.message)\n")
            return .failure
        }
        let a = lines[0]
        let b = lines[1]

        let col2Indent = suppress1 ? "" : "\t"
        let col3Indent =
            (suppress1 ? "" : "\t") + (suppress2 ? "" : "\t")

        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                if !suppress3 { Shell.bashCurrent.stdout(col3Indent + a[i] + "\n") }
                i += 1; j += 1
            } else if a[i] < b[j] {
                if !suppress1 { Shell.bashCurrent.stdout(a[i] + "\n") }
                i += 1
            } else {
                if !suppress2 { Shell.bashCurrent.stdout(col2Indent + b[j] + "\n") }
                j += 1
            }
        }
        while i < a.count {
            if !suppress1 { Shell.bashCurrent.stdout(a[i] + "\n") }
            i += 1
        }
        while j < b.count {
            if !suppress2 { Shell.bashCurrent.stdout(col2Indent + b[j] + "\n") }
            j += 1
        }
        return .success
    }

    private struct CommError: Error { let message: String }

    private static func readBoth(files: [String]) async throws -> [[String]] {
        var stdinUsed = false
        var out: [[String]] = []
        for f in files {
            if f == "-" {
                guard !stdinUsed else {
                    throw CommError(
                        message: "stdin can only be used once")
                }
                stdinUsed = true
                var lines: [String] = []
                for await line in Shell.bashCurrent.stdin.lines { lines.append(line) }
                out.append(lines)
            } else {
                do {
                    let data = try await Shell.bashCurrent.readDataAtPath(f)
                    let text = String(decoding: data, as: UTF8.self)
                    out.append(SortCommand.splitLines(text))
                } catch {
                    throw CommError(message: "\(f): \(error)")
                }
            }
        }
        return out
    }
}
