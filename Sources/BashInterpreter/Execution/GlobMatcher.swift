import Foundation

/// Per-call options for ``GlobMatcher``.
public struct GlobOptions: Sendable {
    /// Allow `?(p) *(p) +(p) @(p) !(p)` extended-glob constructs.
    public var extglob: Bool
    /// Match case-insensitively.
    public var nocase: Bool
    public init(extglob: Bool = false, nocase: Bool = false) {
        self.extglob = extglob
        self.nocase = nocase
    }
    public static let `default` = GlobOptions()
}

/// Glob-style pattern matching for shell `case` patterns, parameter
/// expansion (`${var#pat}` / `${var%pat}`), `[[ s == p ]]`, and
/// filename expansion. Matches bash's `fnmatch(3)`-style behaviour.
///
/// Supported:
/// - `*`  — any sequence of characters, including empty
/// - `?`  — exactly one character
/// - `[abc]`, `[a-z]`, `[!abc]`, `[^abc]` — character class, optionally
///   negated
/// - `\x` — literal `x` (escape)
/// - With `extglob`: `?(p1|p2|…)`, `*(...)`, `+(...)`, `@(...)`,
///   `!(...)` — at-most-one, zero-or-more, one-or-more, exactly-one,
///   and "anything except".
///
/// Not supported yet: `[[:class:]]` POSIX character classes.
enum GlobMatcher {

    /// Returns `true` if `string` matches `pattern` as a bash-style glob.
    static func match(pattern: String, string: String,
                      options: GlobOptions = .default) -> Bool {
        let p = Array(pattern)
        let s = Array(string)
        return match(p, 0, s, 0, options)
    }

    // MARK: Recursive matcher

    private static func match(_ p: [Character], _ pi: Int,
                              _ s: [Character], _ si: Int,
                              _ opts: GlobOptions) -> Bool {
        var pi = pi
        var si = si

        while pi < p.count {
            let c = p[pi]

            // Extended glob constructs: ?(…) *(…) +(…) @(…) !(…)
            if opts.extglob,
               (c == "?" || c == "*" || c == "+" || c == "@" || c == "!"),
               pi + 1 < p.count, p[pi + 1] == "("
            {
                guard let close = matchingParen(p, openIndex: pi + 1)
                else { return false }
                let alts = splitAlternatives(p, from: pi + 2, to: close)
                let rest = Array(p[(close + 1)...])
                return matchExtglob(op: c,
                                    alts: alts,
                                    rest: rest,
                                    s: s, si: si,
                                    opts: opts)
            }

            switch c {
            case "*":
                while pi < p.count, p[pi] == "*" { pi += 1 }
                if pi == p.count { return true }
                var k = si
                while k <= s.count {
                    if match(p, pi, s, k, opts) { return true }
                    k += 1
                }
                return false

            case "?":
                if si >= s.count { return false }
                pi += 1
                si += 1

            case "[":
                if si >= s.count { return false }
                guard let (matched, classEnd) = matchCharClass(p, pi, s[si], opts)
                else { return false }
                if !matched { return false }
                pi = classEnd
                si += 1

            case "\\":
                guard pi + 1 < p.count, si < s.count,
                      sameChar(p[pi + 1], s[si], opts)
                else { return false }
                pi += 2
                si += 1

            default:
                if si >= s.count || !sameChar(s[si], c, opts) { return false }
                pi += 1
                si += 1
            }
        }
        return si == s.count
    }

    // MARK: Extglob

    private static func matchExtglob(op: Character,
                                     alts: [[Character]],
                                     rest: [Character],
                                     s: [Character], si: Int,
                                     opts: GlobOptions) -> Bool
    {
        // Helper: does `pattern` match the prefix of s starting at si,
        // consuming exactly `consumed` characters?
        func consumes(_ alt: [Character], from k: Int) -> [Int] {
            // Try every possible end position for the alt pattern,
            // returning the lengths that yield a full match.
            var lengths: [Int] = []
            for end in k...s.count {
                if match(alt, 0, Array(s[k..<end]), 0, opts) {
                    lengths.append(end - k)
                }
            }
            return lengths
        }

        switch op {
        case "@", "?":
            // @(…): exactly one of the alts. ?(…): at most one.
            if op == "?" {
                // Zero-match path: just match the rest from si.
                if match(rest, 0, s, si, opts) { return true }
            }
            for alt in alts {
                for k in consumes(alt, from: si) {
                    if match(rest, 0, s, si + k, opts) { return true }
                }
            }
            return false

        case "+", "*":
            // +(…): one-or-more. *(…): zero-or-more.
            if op == "*", match(rest, 0, s, si, opts) { return true }
            // BFS over how many alt-units consume the input.
            var positions: Set<Int> = [si]
            // Visit all reachable end positions, then try `rest` at each.
            var visited: Set<Int> = [si]
            var any = false
            while !positions.isEmpty {
                var next: Set<Int> = []
                for p in positions {
                    for alt in alts {
                        for k in consumes(alt, from: p) where k > 0 {
                            let np = p + k
                            if !visited.contains(np) {
                                visited.insert(np)
                                next.insert(np)
                                if op == "+" || op == "*" {
                                    if match(rest, 0, s, np, opts) {
                                        any = true
                                    }
                                }
                            }
                        }
                    }
                }
                positions = next
            }
            return any

        case "!":
            // !(…): match anything that ISN'T the alts. Any prefix of
            // the input that doesn't match any alt, followed by rest
            // matching the remainder.
            for end in si...s.count {
                let prefix = Array(s[si..<end])
                var matchedAny = false
                for alt in alts {
                    if match(alt, 0, prefix, 0, opts) {
                        matchedAny = true; break
                    }
                }
                if !matchedAny, match(rest, 0, s, end, opts) { return true }
            }
            return false

        default:
            return false
        }
    }

    private static func matchingParen(_ p: [Character],
                                      openIndex: Int) -> Int?
    {
        var depth = 0
        var i = openIndex
        while i < p.count {
            let c = p[i]
            if c == "\\", i + 1 < p.count { i += 2; continue }
            if c == "(" { depth += 1 }
            else if c == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// Split `p[from..<to]` on top-level `|` characters.
    private static func splitAlternatives(_ p: [Character],
                                          from: Int, to: Int) -> [[Character]]
    {
        var alts: [[Character]] = [[]]
        var depth = 0
        var i = from
        while i < to {
            let c = p[i]
            if c == "\\", i + 1 < to {
                alts[alts.count - 1].append(c)
                alts[alts.count - 1].append(p[i + 1])
                i += 2; continue
            }
            if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1 }
            if c == "|" && depth == 0 {
                alts.append([])
            } else {
                alts[alts.count - 1].append(c)
            }
            i += 1
        }
        return alts
    }

    private static func sameChar(_ a: Character, _ b: Character,
                                 _ opts: GlobOptions) -> Bool
    {
        if opts.nocase {
            return a.lowercased() == b.lowercased()
        }
        return a == b
    }

    /// Parse a character class starting at `p[pi]` (which is `[`).
    private static func matchCharClass(_ p: [Character], _ pi: Int,
                                       _ c: Character,
                                       _ opts: GlobOptions) -> (Bool, Int)?
    {
        var i = pi + 1
        guard i < p.count else { return nil }

        var negate = false
        if p[i] == "!" || p[i] == "^" {
            negate = true
            i += 1
        }

        var matched = false
        var first = true
        while i < p.count, !(p[i] == "]" && !first) {
            first = false
            let start = p[i]
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                let end = p[i + 2]
                if rangeContains(start: start, end: end, c: c, opts: opts) {
                    matched = true
                }
                i += 3
            } else {
                if sameChar(c, start, opts) { matched = true }
                i += 1
            }
        }
        guard i < p.count, p[i] == "]" else { return nil }
        return (matched != negate, i + 1)
    }

    private static func rangeContains(start: Character, end: Character,
                                      c: Character, opts: GlobOptions) -> Bool
    {
        if opts.nocase {
            let cl = String(c).lowercased()
            let sl = String(start).lowercased()
            let el = String(end).lowercased()
            return cl >= sl && cl <= el
        }
        return c >= start && c <= end
    }
}
