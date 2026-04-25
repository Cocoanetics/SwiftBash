import ArgumentParser
import BashInterpreter
import Foundation

/// `sort [-u] [-n] [-r] [FILE...]` — sort lines.
///
/// With no FILE, reads stdin. Sorts the entire input in memory (no
/// merge-sort spill to disk) — adequate for the inputs we see in
/// practice.
///
/// Supported flags:
/// - `-u` / `--unique` — drop duplicates after sorting
/// - `-n` / `--numeric-sort` — compare by leading numeric prefix
/// - `-r` / `--reverse` — reverse the comparison
///
/// Skipped (low usage in the call-frequency report): `-k FIELD`,
/// `-t SEP`, `-f` ignore-case, `-h` human-numeric.
public struct SortCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sort",
        abstract: "Sort lines."
    )

    @Argument(help: "Files to sort. Reads stdin if empty.")
    public var files: [String] = []

    @Flag(name: [.customShort("u"), .customLong("unique")],
          help: "Suppress duplicate lines.")
    public var unique: Bool = false

    @Flag(name: [.customShort("n"), .customLong("numeric-sort")],
          help: "Compare by leading numeric prefix.")
    public var numeric: Bool = false

    @Flag(name: [.customShort("r"), .customLong("reverse")],
          help: "Reverse the comparison.")
    public var reverse: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var lines: [String] = []
        if files.isEmpty {
            for await line in shell.stdin.lines { lines.append(line) }
        } else {
            for f in files {
                do {
                    let data = try await shell.readDataAtPath(f)
                    let text = String(decoding: data, as: UTF8.self)
                    lines.append(contentsOf: Self.splitLines(text))
                } catch {
                    shell.stderr("sort: \(f): \(error)\n")
                    return .failure
                }
            }
        }

        if numeric {
            lines.sort { Self.numericLess($0, $1) }
        } else {
            lines.sort()
        }
        if reverse { lines.reverse() }
        if unique { lines = Self.collapseAdjacent(lines) }

        for line in lines { shell.stdout(line + "\n") }
        return .success
    }

    // MARK: Helpers

    /// Split text into lines without producing a phantom empty line for
    /// a trailing newline. `"a\nb\n"` → `["a", "b"]`; `"a\nb"` → same.
    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Drop runs of equal adjacent lines; keep the first.
    static func collapseAdjacent(_ lines: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for l in lines {
            if out.last != l { out.append(l) }
        }
        return out
    }

    /// Comparator for `-n`: compare leading numeric prefixes; tie-break
    /// by lexicographic order of the whole line. Non-numeric prefixes
    /// (or absent ones) treat the value as 0, matching GNU sort.
    static func numericLess(_ a: String, _ b: String) -> Bool {
        let na = numericPrefix(a)
        let nb = numericPrefix(b)
        if na != nb { return na < nb }
        return a < b
    }

    static func numericPrefix(_ s: String) -> Double {
        var i = s.startIndex
        while i < s.endIndex, s[i] == " " || s[i] == "\t" {
            i = s.index(after: i)
        }
        let signStart = i
        if i < s.endIndex, s[i] == "-" || s[i] == "+" {
            i = s.index(after: i)
        }
        while i < s.endIndex, s[i].isNumber || s[i] == "." {
            i = s.index(after: i)
        }
        let prefix = s[signStart..<i]
        return Double(prefix) ?? 0
    }
}
