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
        let pat = Array(pattern)
        let str = Array(string)
        return match(pat, 0, str, 0, options)
    }

    // MARK: Recursive matcher

    // swiftlint:disable:next cyclomatic_complexity - glob matcher is inherently branchy
    private static func match(_ pat: [Character], _ patIdx: Int,
                              _ str: [Character], _ strIdx: Int,
                              _ opts: GlobOptions) -> Bool {
        var patIdx = patIdx
        var strIdx = strIdx
        while patIdx < pat.count {
            let char = pat[patIdx]
            // Extended glob constructs: ?(…) *(…) +(…) @(…) !(…)
            if opts.extglob,
               char == "?" || char == "*" || char == "+" || char == "@" || char == "!",
               patIdx + 1 < pat.count, pat[patIdx + 1] == "(" {
                guard let close = matchingParen(pat, openIndex: patIdx + 1)
                else { return false }
                let alts = splitAlternatives(pat, from: patIdx + 2, to: close)
                let rest = Array(pat[(close + 1)...])
                let args = ExtglobArgs(oper: char, alts: alts, rest: rest,
                                       str: str, strIdx: strIdx, opts: opts)
                return matchExtglob(args)
            }
            switch char {
            case "*":
                while patIdx < pat.count, pat[patIdx] == "*" { patIdx += 1 }
                if patIdx == pat.count { return true }
                var split = strIdx
                while split <= str.count {
                    if match(pat, patIdx, str, split, opts) { return true }
                    split += 1
                }
                return false
            case "?":
                if strIdx >= str.count { return false }
                patIdx += 1; strIdx += 1
            case "[":
                if strIdx >= str.count { return false }
                guard let (matched, classEnd) = matchCharClass(pat, patIdx, str[strIdx], opts)
                else { return false }
                if !matched { return false }
                patIdx = classEnd; strIdx += 1
            case "\\":
                guard patIdx + 1 < pat.count, strIdx < str.count,
                      sameChar(pat[patIdx + 1], str[strIdx], opts)
                else { return false }
                patIdx += 2; strIdx += 1
            default:
                if strIdx >= str.count || !sameChar(str[strIdx], char, opts) { return false }
                patIdx += 1; strIdx += 1
            }
        }
        return strIdx == str.count
    }

    // MARK: Extglob

    /// Parameters used by `matchExtglob` (grouped to keep the param count low).
    private struct ExtglobArgs {
        var oper: Character
        var alts: [[Character]]
        var rest: [Character]
        var str: [Character]
        var strIdx: Int
        var opts: GlobOptions
    }

    private static func matchExtglob(_ args: ExtglobArgs) -> Bool {
        switch args.oper {
        case "@", "?": return matchExtglobOptionalOrSingle(args)
        case "+", "*": return matchExtglobRepetition(args)
        case "!": return matchExtglobNegation(args)
        default: return false
        }
    }

    /// Lengths at which `alt` matches a prefix of `str` starting at `from`.
    private static func consumes(_ alt: [Character], from start: Int,
                                 str: [Character],
                                 opts: GlobOptions) -> [Int] {
        var lengths: [Int] = []
        for end in start...str.count where match(alt, 0, Array(str[start..<end]), 0, opts) {
            lengths.append(end - start)
        }
        return lengths
    }

    private static func matchExtglobOptionalOrSingle(_ args: ExtglobArgs) -> Bool {
        // @(…): exactly one of the alts. ?(…): at most one.
        if args.oper == "?" {
            // Zero-match path: just match the rest from strIdx.
            if match(args.rest, 0, args.str, args.strIdx, args.opts) { return true }
        }
        for alt in args.alts {
            for length in consumes(alt, from: args.strIdx, str: args.str, opts: args.opts)
                where match(args.rest, 0, args.str, args.strIdx + length, args.opts) {
                return true
            }
        }
        return false
    }

    private static func matchExtglobRepetition(_ args: ExtglobArgs) -> Bool {
        // +(…): one-or-more. *(…): zero-or-more.
        if args.oper == "*", match(args.rest, 0, args.str, args.strIdx, args.opts) { return true }
        // BFS over how many alt-units consume the input.
        var positions: Set<Int> = [args.strIdx]
        var visited: Set<Int> = [args.strIdx]
        var any = false
        while !positions.isEmpty {
            var next: Set<Int> = []
            for pos in positions {
                for alt in args.alts {
                    for length in consumes(alt, from: pos, str: args.str, opts: args.opts) where length > 0 {
                        let newPos = pos + length
                        if !visited.contains(newPos) {
                            visited.insert(newPos)
                            next.insert(newPos)
                            if match(args.rest, 0, args.str, newPos, args.opts) {
                                any = true
                            }
                        }
                    }
                }
            }
            positions = next
        }
        return any
    }

    private static func matchExtglobNegation(_ args: ExtglobArgs) -> Bool {
        // !(…): match anything that ISN'T the alts. Any prefix of
        // the input that doesn't match any alt, followed by rest
        // matching the remainder.
        for end in args.strIdx...args.str.count {
            let prefix = Array(args.str[args.strIdx..<end])
            var matchedAny = false
            for alt in args.alts where match(alt, 0, prefix, 0, args.opts) {
                matchedAny = true; break
            }
            if !matchedAny, match(args.rest, 0, args.str, end, args.opts) { return true }
        }
        return false
    }

    private static func matchingParen(_ pat: [Character],
                                      openIndex: Int) -> Int? {
        var depth = 0
        var idx = openIndex
        while idx < pat.count {
            let char = pat[idx]
            if char == "\\", idx + 1 < pat.count { idx += 2; continue }
            if char == "(" { depth += 1 } else if char == ")" {
                depth -= 1
                if depth == 0 { return idx }
            }
            idx += 1
        }
        return nil
    }

    /// Split `pat[from..<end]` on top-level `|` characters.
    private static func splitAlternatives(_ pat: [Character],
                                          from: Int, to end: Int) -> [[Character]] {
        var alts: [[Character]] = [[]]
        var depth = 0
        var idx = from
        while idx < end {
            let char = pat[idx]
            if char == "\\", idx + 1 < end {
                alts[alts.count - 1].append(char)
                alts[alts.count - 1].append(pat[idx + 1])
                idx += 2; continue
            }
            if char == "(" { depth += 1 } else if char == ")" { depth -= 1 }
            if char == "|" && depth == 0 {
                alts.append([])
            } else {
                alts[alts.count - 1].append(char)
            }
            idx += 1
        }
        return alts
    }

    private static func sameChar(_ lhs: Character, _ rhs: Character,
                                 _ opts: GlobOptions) -> Bool {
        if opts.nocase {
            return lhs.lowercased() == rhs.lowercased()
        }
        return lhs == rhs
    }

    /// Parse a character class starting at `pat[patIdx]` (which is `[`).
    private static func matchCharClass(_ pat: [Character], _ patIdx: Int,
                                       _ char: Character,
                                       _ opts: GlobOptions) -> (Bool, Int)? {
        var idx = patIdx + 1
        guard idx < pat.count else { return nil }

        var negate = false
        if pat[idx] == "!" || pat[idx] == "^" {
            negate = true
            idx += 1
        }

        var matched = false
        var first = true
        while idx < pat.count, !(pat[idx] == "]" && !first) {
            first = false
            let start = pat[idx]
            if idx + 2 < pat.count, pat[idx + 1] == "-", pat[idx + 2] != "]" {
                let end = pat[idx + 2]
                if rangeContains(start: start, end: end, char: char, opts: opts) {
                    matched = true
                }
                idx += 3
            } else {
                if sameChar(char, start, opts) { matched = true }
                idx += 1
            }
        }
        guard idx < pat.count, pat[idx] == "]" else { return nil }
        return (matched != negate, idx + 1)
    }

    private static func rangeContains(start: Character, end: Character,
                                      char: Character, opts: GlobOptions) -> Bool {
        if opts.nocase {
            let charLower = String(char).lowercased()
            let startLower = String(start).lowercased()
            let endLower = String(end).lowercased()
            return charLower >= startLower && charLower <= endLower
        }
        return char >= start && char <= end
    }
}
