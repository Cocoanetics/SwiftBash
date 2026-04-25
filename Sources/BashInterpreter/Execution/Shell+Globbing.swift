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
                    originalWord: Node) async throws -> [String]
    {
        guard shouldGlob(originalWord) else { return [expanded] }
        let matches = await glob(expanded)
        return matches.isEmpty ? [expanded] : matches
    }

    /// True when the *raw source* of `word` contains a glob
    /// metacharacter (`*`, `?`, `[`) outside of any quoted region —
    /// matching bash's rule that quotes suppress pathname expansion.
    private func shouldGlob(_ word: Node) -> Bool {
        let chars = Array(currentSource)
        let lo = max(0, word.range.lowerBound)
        let hi = min(chars.count, word.range.upperBound)
        guard lo < hi else { return false }

        var i = lo
        while i < hi {
            let c = chars[i]
            if c == "'" {
                i += 1
                while i < hi, chars[i] != "'" { i += 1 }
                if i < hi { i += 1 }
                continue
            }
            if c == "\"" {
                i += 1
                while i < hi, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < hi { i += 2; continue }
                    i += 1
                }
                if i < hi { i += 1 }
                continue
            }
            if c == "\\" { i += 2; continue }
            if c == "*" || c == "?" || c == "[" { return true }
            i += 1
        }
        return false
    }

    /// Expand `pattern` against ``fileSystem``. Splits the pattern at
    /// its final slash and globs only the tail component. Hidden
    /// entries (those starting with `.`) are excluded unless the
    /// pattern itself starts with `.`.
    private func glob(_ pattern: String) async -> [String] {
        let (dirPart, fileGlob) = splitGlobPattern(pattern)
        let dirAbs = resolvePath(dirPart)
        let entries: [String]
        do {
            entries = try await fileSystem.list(dirAbs)
        } catch {
            return []
        }

        let includeHidden = fileGlob.hasPrefix(".")
        var matches: [String] = []
        for name in entries {
            if !includeHidden && name.hasPrefix(".") { continue }
            if GlobMatcher.match(pattern: fileGlob, string: name) {
                let prefix = dirPart.isEmpty || dirPart == "."
                    ? ""
                    : (dirPart.hasSuffix("/") ? dirPart : dirPart + "/")
                matches.append(prefix + name)
            }
        }
        return matches.sorted()
    }

    /// `foo/bar/*.txt` → (`foo/bar`, `*.txt`). `*.txt` → (`.`, `*.txt`).
    private func splitGlobPattern(_ pattern: String) -> (String, String) {
        if let lastSlash = pattern.lastIndex(of: "/") {
            let dir = String(pattern[..<lastSlash])
            let tail = String(pattern[pattern.index(after: lastSlash)...])
            return (dir.isEmpty ? "/" : dir, tail)
        }
        return (".", pattern)
    }
}
