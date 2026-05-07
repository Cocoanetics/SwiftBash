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

    public mutating func execute() async throws -> ExitStatus {
        var unifiedContext: Int? = nil
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-u" || a == "--unified" {
                // Optional numeric arg.
                if i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]) {
                    unifiedContext = n
                    i += 2; continue
                }
                unifiedContext = 3; i += 1; continue
            }
            // `-uN` combined.
            if a.hasPrefix("-u"), let n = Int(a.dropFirst(2)) {
                unifiedContext = n; i += 1; continue
            }
            if a.hasPrefix("--unified="),
               let n = Int(a.dropFirst("--unified=".count))
            {
                unifiedContext = n; i += 1; continue
            }
            if a.hasPrefix("-"), a.count > 1, a != "-" {
                Shell.bashCurrent.stderr("diff: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
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

    // MARK: Normal renderer

    /// Group consecutive removals/additions into BSD/GNU "normal" diff
    /// hunks: `1d0`, `2c2`, `0a1` and so on.
    static func renderNormal(merged: [MergedLine]) -> String {
        struct Hunk {
            var removed: [(line: Int, text: String)] = []
            var added:   [(line: Int, text: String)] = []
        }
        var hunks: [Hunk] = []
        var current = Hunk()
        for line in merged {
            switch line {
            case .context:
                if !current.removed.isEmpty || !current.added.isEmpty {
                    hunks.append(current)
                    current = Hunk()
                }
            case .removed(let n, let t):
                current.removed.append((n, t))
            case .added(let n, let t):
                current.added.append((n, t))
            }
        }
        if !current.removed.isEmpty || !current.added.isEmpty {
            hunks.append(current)
        }

        var out = ""
        for h in hunks {
            let oldRange = h.removed.isEmpty
                ? "\(max(0, h.added.first!.line - 1))"
                : range(lines: h.removed.map(\.line))
            let newRange = h.added.isEmpty
                ? "\(max(0, h.removed.first!.line - 1))"
                : range(lines: h.added.map(\.line))
            let op: Character
            if h.removed.isEmpty { op = "a" }
            else if h.added.isEmpty { op = "d" }
            else { op = "c" }
            out += "\(oldRange)\(op)\(newRange)\n"
            for (_, t) in h.removed { out += "< \(t)\n" }
            if !h.removed.isEmpty, !h.added.isEmpty { out += "---\n" }
            for (_, t) in h.added { out += "> \(t)\n" }
        }
        return out
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
