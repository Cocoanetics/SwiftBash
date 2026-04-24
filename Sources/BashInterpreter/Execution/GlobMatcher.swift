import Foundation

/// Glob-style pattern matching for shell `case` patterns (and, later,
/// filename expansion). Matches bash's `fnmatch(3)`-style behaviour for
/// the common metacharacters.
///
/// Supported:
/// - `*`  — any sequence of characters, including empty
/// - `?`  — exactly one character
/// - `[abc]`, `[a-z]`, `[!abc]`, `[^abc]` — character class, optionally
///   negated
/// - `\x` — literal `x` (escape)
///
/// Not supported yet: extended globs (`?(…)`, `*(…)`, `+(…)`, `@(…)`,
/// `!(…)`), `[[:class:]]` POSIX character classes.
enum GlobMatcher {

    /// Returns `true` if `string` matches `pattern` as a bash-style glob.
    static func match(pattern: String, string: String) -> Bool {
        let p = Array(pattern)
        let s = Array(string)
        return match(p, 0, s, 0)
    }

    // MARK: Recursive matcher

    private static func match(_ p: [Character], _ pi: Int,
                              _ s: [Character], _ si: Int) -> Bool {
        var pi = pi
        var si = si

        while pi < p.count {
            let c = p[pi]

            switch c {
            case "*":
                // Collapse runs of `*` to one.
                while pi < p.count, p[pi] == "*" { pi += 1 }
                // Trailing `*` matches anything remaining.
                if pi == p.count { return true }
                // Try to match the remainder of the pattern against every
                // suffix of the input.
                var k = si
                while k <= s.count {
                    if match(p, pi, s, k) { return true }
                    k += 1
                }
                return false

            case "?":
                if si >= s.count { return false }
                pi += 1
                si += 1

            case "[":
                if si >= s.count { return false }
                guard let (matched, classEnd) = matchCharClass(p, pi, s[si])
                else { return false }
                if !matched { return false }
                pi = classEnd
                si += 1

            case "\\":
                guard pi + 1 < p.count, si < s.count,
                      p[pi + 1] == s[si]
                else { return false }
                pi += 2
                si += 1

            default:
                if si >= s.count || s[si] != c { return false }
                pi += 1
                si += 1
            }
        }
        return si == s.count
    }

    /// Parse a character class starting at `p[pi]` (which is `[`).
    /// Returns whether `c` matched and the position one past the closing `]`.
    private static func matchCharClass(_ p: [Character], _ pi: Int,
                                       _ c: Character) -> (Bool, Int)? {
        var i = pi + 1
        guard i < p.count else { return nil }

        var negate = false
        if p[i] == "!" || p[i] == "^" {
            negate = true
            i += 1
        }

        // A `]` in the first position is a literal ].
        var matched = false
        var first = true
        while i < p.count, !(p[i] == "]" && !first) {
            first = false
            let start = p[i]
            // Range: `a-z`
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                let end = p[i + 2]
                if c >= start && c <= end { matched = true }
                i += 3
            } else {
                if c == start { matched = true }
                i += 1
            }
        }
        guard i < p.count, p[i] == "]" else { return nil }
        return (matched != negate, i + 1)
    }
}
