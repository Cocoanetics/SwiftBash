import ArgumentParser
import BashInterpreter
import Foundation

/// `diff [-u [N]] FILE1 FILE2` — line-level diff.
///
/// Default format is the classic `<`/`>` "normal" diff (matching BSD/GNU
/// `diff`). Pass `-u` for unified format with 3 lines of context, or
/// `-u N` to override the context size.
///
/// ### Exit status
/// - `0` — files are identical
/// - `1` — files differ
/// - `2` — error (missing file, etc.)
///
/// Backed by `Swift.CollectionDifference` (an O(ND) Myers diff in the
/// stdlib).
///
/// Out of scope: context format (`-c`), brief mode (`-q`), recursive
/// (`-r`), whitespace flags (`-w`/`-b`), case-insensitive (`-i`).
public struct DiffCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Line-level diff (normal `<`/`>` by default; `-u` for unified)."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then FILE1 FILE2.")
    public var rawArgv: [String] = []

    public init() {}

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var unifiedContext: Int?
        var files: [String] = []

        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "--" {
                idx += 1
                while idx < rawArgv.count { files.append(rawArgv[idx]); idx += 1 }
                break
            }
            if arg == "-u" || arg == "--unified" {
                // Optional numeric arg.
                if idx + 1 < rawArgv.count, let num = Int(rawArgv[idx + 1]) {
                    unifiedContext = num
                    idx += 2; continue
                }
                unifiedContext = 3; idx += 1; continue
            }
            // `-uN` combined.
            if arg.hasPrefix("-u"), let num = Int(arg.dropFirst(2)) {
                unifiedContext = num; idx += 1; continue
            }
            if arg.hasPrefix("--unified="),
               let num = Int(arg.dropFirst("--unified=".count)) {
                unifiedContext = num; idx += 1; continue
            }
            if arg.hasPrefix("-"), arg.count > 1, arg != "-" {
                Shell.bashCurrent.stderr("diff: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            files.append(arg); idx += 1
        }

        guard files.count == 2 else {
            Shell.bashCurrent.stderr("diff: expected two file arguments\n")
            return ExitStatus(2)
        }
        if let ctx = unifiedContext, ctx < 0 {
            Shell.bashCurrent.stderr("diff: -u must be ≥ 0\n")
            return ExitStatus(2)
        }
        let aLines: [String]
        let bLines: [String]
        do {
            aLines = try await Self.readLines(at: files[0])
            bLines = try await Self.readLines(at: files[1])
        } catch let err as DiffError {
            Shell.bashCurrent.stderr("diff: \(err.message)\n")
            return ExitStatus(2)
        }

        if aLines == bLines { return .success }

        let merged = Self.mergeLines(old: aLines, new: bLines)
        let output: String
        if let ctx = unifiedContext {
            output = Self.renderUnified(
                merged: merged, context: ctx,
                oldName: files[0], newName: files[1])
        } else {
            output = Self.renderNormal(merged: merged)
        }
        Shell.bashCurrent.stdout(output)
        return .failure
    }

    // MARK: I/O

    private struct DiffError: Error { let message: String }

    private static func readLines(at path: String) async throws -> [String] {
        if path == "-" {
            var lines: [String] = []
            for await line in Shell.bashCurrent.stdin.lines { lines.append(line) }
            return lines
        }
        do {
            let data = try await Shell.bashCurrent.readDataAtPath(path)
            // diff input may legitimately contain non-UTF-8 byte sequences
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: data, as: UTF8.self)
            return SortCommand.splitLines(text)
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
        var oldIdx = 0
        var newIdx = 0
        while oldIdx < old.count || newIdx < new.count {
            if let removed = removes[oldIdx] {
                out.append(.removed(oldNum: oldIdx + 1, text: removed))
                oldIdx += 1
            } else if let inserted = inserts[newIdx] {
                out.append(.added(newNum: newIdx + 1, text: inserted))
                newIdx += 1
            } else {
                out.append(.context(
                    oldNum: oldIdx + 1, newNum: newIdx + 1, text: old[oldIdx]))
                oldIdx += 1
                newIdx += 1
            }
        }
        return out
    }

    // MARK: Normal renderer

    // Group consecutive removals/additions into BSD/GNU "normal" diff
    // hunks: `1d0`, `2c2`, `0a1` and so on.
    // swiftlint:disable:next cyclomatic_complexity
    static func renderNormal(merged: [MergedLine]) -> String {
        var hunks: [DiffHunk] = []
        var current = DiffHunk()
        for line in merged {
            switch line {
            case .context:
                if !current.removed.isEmpty || !current.added.isEmpty {
                    hunks.append(current)
                    current = DiffHunk()
                }
            case .removed(let lineNum, let text):
                current.removed.append((lineNum, text))
            case .added(let lineNum, let text):
                current.added.append((lineNum, text))
            }
        }
        if !current.removed.isEmpty || !current.added.isEmpty {
            hunks.append(current)
        }

        var out = ""
        for hunk in hunks {
            let oldRange = hunk.removed.isEmpty
                ? "\(max(0, hunk.added.first!.line - 1))"
                : range(lines: hunk.removed.map(\.line))
            let newRange = hunk.added.isEmpty
                ? "\(max(0, hunk.removed.first!.line - 1))"
                : range(lines: hunk.added.map(\.line))
            let action: Character
            if hunk.removed.isEmpty {
                action = "a"
            } else if hunk.added.isEmpty {
                action = "d"
            } else {
                action = "c"
            }
            out += "\(oldRange)\(action)\(newRange)\n"
            for (_, text) in hunk.removed { out += "< \(text)\n" }
            if !hunk.removed.isEmpty, !hunk.added.isEmpty { out += "---\n" }
            for (_, text) in hunk.added { out += "> \(text)\n" }
        }
        return out
    }

    /// Hunk used by ``renderNormal``; one entry per `<add/del/change>` block.
    private struct DiffHunk {
        var removed: [(line: Int, text: String)] = []
        var added: [(line: Int, text: String)] = []
    }

    private static func range(lines: [Int]) -> String {
        guard let first = lines.first, let last = lines.last else { return "0" }
        return first == last ? "\(first)" : "\(first),\(last)"
    }

    // MARK: Unified renderer

    /// Group the merged-diff stream into hunks (changes plus N
    /// surrounding context lines) and emit the unified-diff text.
    static func renderUnified(merged: [MergedLine],
                              context: Int,
                              oldName: String,
                              newName: String) -> String {
        // Indices of non-context lines.
        let changeIdxs = merged.enumerated().compactMap { idx, line -> Int? in
            line.isContext ? nil : idx
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

    // Render one hunk: a `@@ -ostart,olen +nstart,nlen @@` header
    // followed by ` `/`-`/`+` prefixed lines. Length-zero ranges
    // (pure additions or pure deletions) drop the comma form per
    // the unified-format spec.
    // swiftlint:disable:next cyclomatic_complexity
    private static func renderHunk(_ lines: ArraySlice<MergedLine>) -> String {
        var oldStart = 0
        var newStart = 0
        var oldLen = 0
        var newLen = 0
        for line in lines {
            switch line {
            case .context(let oldNum, let newNum, _):
                if oldStart == 0 { oldStart = oldNum }
                if newStart == 0 { newStart = newNum }
                oldLen += 1
                newLen += 1
            case .removed(let oldNum, _):
                if oldStart == 0 { oldStart = oldNum }
                oldLen += 1
            case .added(let newNum, _):
                if newStart == 0 { newStart = newNum }
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
