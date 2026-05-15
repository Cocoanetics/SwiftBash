import Foundation
import BashSyntax

extension Shell {

    /// Expand glob metacharacters (`*`, `?`, `[...]`) in a word that
    /// has already had variable and command substitution applied.
    ///
    /// Returns a list of file paths when the pattern matches, or a
    /// single-element `[expanded]` list when it doesn't (matching
    /// bash's default "keep pattern literal" behaviour without
    /// `nullglob`). Also returns `[expanded]` verbatim when the
    /// original source between `originalWord.range` had all its glob
    /// chars inside quotes — `echo "*.txt"` never globs.
    ///
    /// This is a pragmatic subset: only the *last* path component is
    /// treated as a pattern. `dir/*.txt` works; `*/file.txt` doesn't
    /// expand the first component and is returned literally.
    func globExpand(_ expanded: String,
                    originalWord: Node) async throws -> [String] {
        guard shouldGlob(originalWord) else { return [expanded] }
        let matches = await glob(expanded)
        if !matches.isEmpty { return matches }
        // `nullglob`: drop the unmatched pattern entirely (yielding zero
        // args) instead of leaving it as a literal.
        if shoptOptions["nullglob"] == true { return [] }
        return [expanded]
    }

    // True when the *raw source* of `word` contains a glob
    // metacharacter (`*`, `?`, `[`) outside of any quoted region —
    // matching bash's rule that quotes suppress pathname expansion.
    //
    // Quote-state scanner over the raw word source; per-quote helpers
    // would obscure the linear depth-tracking loop.
    // swiftlint:disable:next cyclomatic_complexity
    private func shouldGlob(_ word: Node) -> Bool {
        let chars = Array(currentSource)
        let low = max(0, word.range.lowerBound)
        let high = min(chars.count, word.range.upperBound)
        guard low < high else { return false }

        var idx = low
        while idx < high {
            let char = chars[idx]
            if char == "'" {
                idx += 1
                while idx < high, chars[idx] != "'" { idx += 1 }
                if idx < high { idx += 1 }
                continue
            }
            if char == "\"" {
                idx += 1
                while idx < high, chars[idx] != "\"" {
                    if chars[idx] == "\\", idx + 1 < high { idx += 2; continue }
                    idx += 1
                }
                if idx < high { idx += 1 }
                continue
            }
            if char == "\\" { idx += 2; continue }
            if char == "*" || char == "?" || char == "[" { return true }
            idx += 1
        }
        return false
    }

    /// Expand `pattern` against ``fileSystem``. Walks every segment of
    /// the path, applying glob matching at each level. The leading
    /// portion (everything up to the first segment containing a glob
    /// metacharacter) is treated as a literal directory.
    ///
    /// `globstar`-aware: when enabled, a segment that is exactly `**`
    /// matches zero or more directory levels.
    private func glob(_ pattern: String) async -> [String] {
        guard !pattern.isEmpty else { return [] }
        let absolute = pattern.hasPrefix("/")
        let segments = pattern.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !segments.isEmpty else { return [] }

        let startBase = absolute ? "/" : "."
        let matched = await globRecursive(
            base: startBase, segments: segments, segIdx: 0,
            isAbsolute: absolute)
        return matched.sorted()
    }

    /// Recursively glob segment-by-segment under `base`. Each level
    /// reads `base`'s directory entries, matches them against the
    /// segment pattern, and recurses into the matches.
    private func globRecursive(base: String,
                               segments: [String],
                               segIdx: Int,
                               isAbsolute: Bool) async -> [String] {
        if segIdx >= segments.count {
            // Past the last segment — emit `base` if it actually exists.
            let resolved = resolvePath(base)
            if (try? await fileSystem.metadata(resolved)) != nil {
                return [pretty(base, isAbsolute: isAbsolute)]
            }
            return []
        }

        let seg = segments[segIdx]
        let isLast = (segIdx == segments.count - 1)

        // `**` (globstar): match zero or more path segments.
        if seg == "**", shoptOptions["globstar"] == true {
            var out: [String] = []
            // Zero levels: skip past the `**` segment.
            out.append(contentsOf: await globRecursive(
                base: base, segments: segments, segIdx: segIdx + 1,
                isAbsolute: isAbsolute))
            // One-or-more levels: descend into every directory under base
            // (including base's children, recursively), keeping `**` as
            // the current segment.
            let dirs = await listDirectoriesRecursive(under: base)
            for dir in dirs {
                out.append(contentsOf: await globRecursive(
                    base: dir, segments: segments, segIdx: segIdx + 1,
                    isAbsolute: isAbsolute))
            }
            return out
        }

        // Plain segment: list the dir, match each entry.
        let resolvedBase = resolvePath(base)
        let entries: [FileEntry]
        do { entries = try await fileSystem.list(resolvedBase) } catch { return [] }

        let includeHidden = seg.hasPrefix(".")
            || shoptOptions["dotglob"] == true
        var out: [String] = []
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            let name = entry.name
            if !includeHidden && name.hasPrefix(".") { continue }
            if !matches(pattern: seg, string: name) { continue }
            let next = base == "/" ? "/" + name
                : (base == "." ? name : base + "/" + name)
            if isLast {
                out.append(pretty(next, isAbsolute: isAbsolute))
            } else if entry.metadata.kind == .directory {
                out.append(contentsOf: await globRecursive(
                    base: next, segments: segments, segIdx: segIdx + 1,
                    isAbsolute: isAbsolute))
            }
        }
        return out
    }

    /// Single-segment match honouring `nocaseglob` / `extglob`.
    private func matches(pattern: String, string: String) -> Bool {
        let opts = GlobOptions(
            extglob: shoptOptions["extglob"] == true,
            nocase: shoptOptions["nocaseglob"] == true)
        return GlobMatcher.match(pattern: pattern, string: string, options: opts)
    }

    /// Recursively enumerate every directory under `base` (excluding
    /// `base` itself). Used to power `globstar`.
    private func listDirectoriesRecursive(under base: String) async -> [String] {
        var out: [String] = []
        let baseAbs = resolvePath(base)
        let entries = (try? await fileSystem.list(baseAbs)) ?? []
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            let name = entry.name
            // Globstar excludes hidden dirs unless dotglob is on.
            if shoptOptions["dotglob"] != true, name.hasPrefix(".") {
                continue
            }
            guard entry.metadata.kind == .directory else { continue }
            let child = base == "/" ? "/" + name
                : (base == "." ? name : base + "/" + name)
            out.append(child)
            out.append(contentsOf:
                        await listDirectoriesRecursive(under: child))
        }
        return out
    }

    private func pretty(_ path: String, isAbsolute: Bool) -> String {
        if isAbsolute { return path }
        if path.hasPrefix("./") { return String(path.dropFirst(2)) }
        return path
    }
}
