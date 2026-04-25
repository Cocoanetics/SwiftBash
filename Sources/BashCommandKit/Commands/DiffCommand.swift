import ArgumentParser
import BashInterpreter
import Foundation

/// `diff [-u N] FILE1 FILE2` — line-level unified diff.
///
/// Output is **always** unified format (real `diff`'s default is the
/// classic `<`/`>` form, which scripts no longer use). Pass `-u N` to
/// override the default context size of 3 lines; `-u` alone keeps the
/// default. Use `-` for either FILE to read from stdin (only once).
///
/// ### Exit status
/// - `0` — files are identical
/// - `1` — files differ
/// - `2` — error (missing file, etc.)
///
/// Backed by `Swift.CollectionDifference` (an O(ND) Myers diff in the
/// stdlib) — no third-party diff dependency.
///
/// Out of scope: classic format (`<`/`>`), context format (`-c`),
/// brief mode (`-q`), recursive (`-r`), whitespace flags (`-w`/`-b`),
/// case-insensitive (`-i`).
public struct DiffCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Unified line-level diff (always -u)."
    )

    @Option(name: [.customShort("u"), .customLong("unified")],
            help: "Context lines around each change (default: 3).")
    public var unified: Int = 3

    @Argument(help: "Two files to compare (use `-` for stdin, once).")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard files.count == 2 else {
            shell.stderr("diff: expected two file arguments\n")
            return ExitStatus(2)
        }
        guard unified >= 0 else {
            shell.stderr("diff: -u must be ≥ 0\n")
            return ExitStatus(2)
        }
        let aLines: [String]
        let bLines: [String]
        do {
            aLines = try await Self.readLines(at: files[0], shell: shell)
            bLines = try await Self.readLines(at: files[1], shell: shell)
        } catch let err as DiffError {
            shell.stderr("diff: \(err.message)\n")
            return ExitStatus(2)
        }

        if aLines == bLines { return .success }

        let merged = Self.mergeLines(old: aLines, new: bLines)
        let output = Self.renderUnified(
            merged: merged,
            context: unified,
            oldName: files[0],
            newName: files[1])
        shell.stdout(output)
        return .failure
    }

    // MARK: I/O

    private struct DiffError: Error { let message: String }

    private static func readLines(at path: String,
                                  shell: Shell) async throws -> [String] {
        if path == "-" {
            var lines: [String] = []
            for await line in shell.stdin.lines { lines.append(line) }
            return lines
        }
        do {
            let data = try await shell.readDataAtPath(path)
            return SortCommand.splitLines(
                String(decoding: data, as: UTF8.self))
        } catch {
            throw DiffError(message: "\(path): \(error)")
        }
    }

    // MARK: Diff merge

    /// One step in the merged-diff sequence: either a context line (the
    /// same in both inputs), a removal (only in old), or an addition
    /// (only in new). Line numbers are 1-based.
    enum MergedLine: Equatable {
        case context(oldNum: Int, newNum: Int, text: String)
        case removed(oldNum: Int, text: String)
        case added(newNum: Int, text: String)

        var isContext: Bool {
            if case .context = self { return true }
            return false
        }
    }

    /// Run `CollectionDifference` and replay it as a sequence of
    /// `MergedLine`s. The stdlib's diff is over inserts/removes by
    /// offset; we just walk the two arrays in lockstep, consulting
    /// the change tables.
    static func mergeLines(old: [String], new: [String]) -> [MergedLine] {
        let diff = new.difference(from: old)
        var removes: [Int: String] = [:]
        var inserts: [Int: String] = [:]
        for change in diff {
            switch change {
            case .remove(let off, let elem, _): removes[off] = elem
            case .insert(let off, let elem, _): inserts[off] = elem
            }
        }

        var out: [MergedLine] = []
        var oi = 0
        var ni = 0
        while oi < old.count || ni < new.count {
            if let r = removes[oi] {
                out.append(.removed(oldNum: oi + 1, text: r))
                oi += 1
            } else if let i = inserts[ni] {
                out.append(.added(newNum: ni + 1, text: i))
                ni += 1
            } else {
                out.append(.context(
                    oldNum: oi + 1, newNum: ni + 1, text: old[oi]))
                oi += 1
                ni += 1
            }
        }
        return out
    }

    // MARK: Unified renderer

    /// Group the merged-diff stream into hunks (changes plus N
    /// surrounding context lines) and emit the unified-diff text.
    static func renderUnified(merged: [MergedLine],
                              context: Int,
                              oldName: String,
                              newName: String) -> String {
        // Indices of non-context lines.
        let changeIdxs = merged.enumerated().compactMap { i, line -> Int? in
            line.isContext ? nil : i
        }
        guard !changeIdxs.isEmpty else { return "" }

        // Cluster changes whose surrounding context windows touch.
        // Two changes share a hunk when at most `2 * context` context
        // lines separate them (otherwise the windows wouldn't touch).
        var clusters: [[Int]] = [[changeIdxs[0]]]
        for idx in changeIdxs.dropFirst() {
            if idx - clusters[clusters.count - 1].last! <= 2 * context + 1 {
                clusters[clusters.count - 1].append(idx)
            } else {
                clusters.append([idx])
            }
        }

        var output = "--- \(oldName)\n+++ \(newName)\n"
        for cluster in clusters {
            let start = max(0, cluster.first! - context)
            let end = min(merged.count, cluster.last! + context + 1)
            output += renderHunk(merged[start..<end])
        }
        return output
    }

    /// Render one hunk: a `@@ -ostart,olen +nstart,nlen @@` header
    /// followed by ` `/`-`/`+` prefixed lines. Length-zero ranges
    /// (pure additions or pure deletions) drop the comma form per
    /// the unified-format spec.
    private static func renderHunk(_ lines: ArraySlice<MergedLine>) -> String {
        var oldStart = 0
        var newStart = 0
        var oldLen = 0
        var newLen = 0
        for line in lines {
            switch line {
            case .context(let o, let n, _):
                if oldStart == 0 { oldStart = o }
                if newStart == 0 { newStart = n }
                oldLen += 1
                newLen += 1
            case .removed(let o, _):
                if oldStart == 0 { oldStart = o }
                oldLen += 1
            case .added(let n, _):
                if newStart == 0 { newStart = n }
                newLen += 1
            }
        }
        // Empty side → start = 0; pure add/delete is rare in real diffs
        // because hunks always have at least the changes themselves,
        // but the spec uses N,0 for add-only and N for the "before"
        // address when the file was empty.
        let oldHeader = oldLen == 1
            ? "\(oldStart)"
            : "\(oldStart == 0 ? 0 : oldStart),\(oldLen)"
        let newHeader = newLen == 1
            ? "\(newStart)"
            : "\(newStart == 0 ? 0 : newStart),\(newLen)"

        var hunk = "@@ -\(oldHeader) +\(newHeader) @@\n"
        for line in lines {
            switch line {
            case .context(_, _, let text): hunk += " \(text)\n"
            case .removed(_, let text):    hunk += "-\(text)\n"
            case .added(_, let text):      hunk += "+\(text)\n"
            }
        }
        return hunk
    }
}
