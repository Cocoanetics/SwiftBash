import Foundation

/// Bash-style brace expansion for a single argv fragment.
///
/// Supports:
/// - List form `{a,b,c}` → `a b c`. Items may themselves be empty
///   (`{a,,b}` → `a`, ``, `b`).
/// - Sequence form `{N..M}` and `{N..M..step}` for integers
///   (`{1..3}` → `1 2 3`; `{5..1..2}` → `5 3 1`). Zero-padding
///   is preserved when both endpoints carry it (`{01..03}` → `01 02 03`).
/// - Single-character ranges `{a..e}` → `a b c d e`.
///
/// A pattern with no top-level brace pair, or whose braces don't contain
/// a comma or `..`, is returned unchanged.
///
/// **Quoting limitation.** Brace expansion runs after argv assembly,
/// where quote provenance is lost. A literal `'{a,b}'` written by the
/// user would also expand here, unlike bash. Real-world impact is small
/// because explicit braces inside quotes are rare; if needed, escape the
/// brace (`\{a,b\}` → currently passes through as `{a,b}`).
enum BraceExpansion {

    static func expand(_ input: String) -> [String] {
        return expandSearching(input, fromIndex: 0)
    }

    /// Walk the input from `fromIndex`, looking for the first brace pair
    /// that yields a valid expansion. Pairs that don't (no top-level
    /// comma and not a numeric/char range) are stepped over so we never
    /// re-process the same brace.
    private static func expandSearching(_ input: String,
                                        fromIndex: Int) -> [String] {
        let chars = Array(input)
        var search = fromIndex
        while let braces = findTopLevelBraceGroup(chars: chars,
                                                  fromIndex: search) {
            let prefix = String(chars[..<braces.openIndex])
            let inner = String(chars[(braces.openIndex + 1)..<braces.closeIndex])
            let suffix = String(chars[(braces.closeIndex + 1)...])

            let parts: [String]?
            if let seq = expandSequence(inner) {
                parts = seq
            } else {
                let items = splitTopLevelCommas(inner)
                parts = items.count > 1 ? items : nil
            }

            guard let parts else {
                // This `{…}` is a literal — move past it and keep looking
                // for the next brace group in the same input.
                search = braces.closeIndex + 1
                continue
            }

            var out: [String] = []
            for part in parts {
                // Recursively expand the suffix only — the prefix is
                // brace-free (all earlier braces were skipped or absent).
                for tail in expandSearching(part + suffix, fromIndex: 0) {
                    out.append(prefix + tail)
                }
            }
            return out
        }
        return [input]
    }

    // MARK: Locate matching braces

    private struct BracePair {
        let openIndex: Int
        let closeIndex: Int
    }

    private static func findTopLevelBraceGroup(chars: [Character],
                                               fromIndex: Int) -> BracePair? {
        var idx = fromIndex
        while idx < chars.count {
            let char = chars[idx]
            if char == "\\", idx + 1 < chars.count {
                idx += 2; continue
            }
            if char == "{" {
                if let close = matchingBrace(chars: chars, openIndex: idx) {
                    return BracePair(openIndex: idx, closeIndex: close)
                }
            }
            idx += 1
        }
        return nil
    }

    private static func matchingBrace(chars: [Character],
                                      openIndex: Int) -> Int? {
        var depth = 0
        var idx = openIndex
        while idx < chars.count {
            let char = chars[idx]
            if char == "\\", idx + 1 < chars.count {
                idx += 2; continue
            }
            if char == "{" { depth += 1 } else if char == "}" {
                depth -= 1
                if depth == 0 { return idx }
            }
            idx += 1
        }
        return nil
    }

    private static func splitTopLevelCommas(_ input: String) -> [String] {
        var parts: [String] = [""]
        var depth = 0
        let chars = Array(input)
        var idx = 0
        while idx < chars.count {
            let char = chars[idx]
            if char == "\\", idx + 1 < chars.count {
                parts[parts.count - 1].append(char)
                parts[parts.count - 1].append(chars[idx + 1])
                idx += 2; continue
            }
            if char == "{" { depth += 1 } else if char == "}" { depth -= 1 }
            if char == "," && depth == 0 {
                parts.append("")
            } else {
                parts[parts.count - 1].append(char)
            }
            idx += 1
        }
        return parts
    }

    // MARK: Sequence form

    private static func expandSequence(_ inner: String) -> [String]? {
        // Split on `..` at top level.
        let segs = splitOnDotDot(inner)
        guard segs.count == 2 || segs.count == 3 else { return nil }

        // Integer sequence?
        if let from = Int(segs[0]), let toEnd = Int(segs[1]) {
            let step: Int
            if segs.count == 3 {
                guard let stepValue = Int(segs[2]), stepValue != 0 else { return nil }
                step = abs(stepValue) * (from <= toEnd ? 1 : -1)
            } else {
                step = from <= toEnd ? 1 : -1
            }
            let pad = max(zeroPad(segs[0]), zeroPad(segs[1]))
            var values: [String] = []
            var current = from
            while step > 0 ? current <= toEnd : current >= toEnd {
                values.append(formatInt(current, padTo: pad))
                current += step
            }
            return values
        }

        // Single-character range?
        if segs[0].count == 1, segs[1].count == 1,
           let fromChar = segs[0].first, let toChar = segs[1].first,
           fromChar.isASCII, toChar.isASCII {
            let fromAscii = Int(fromChar.asciiValue!)
            let toAscii = Int(toChar.asciiValue!)
            let step: Int
            if segs.count == 3 {
                guard let stepValue = Int(segs[2]), stepValue != 0 else { return nil }
                step = abs(stepValue) * (fromAscii <= toAscii ? 1 : -1)
            } else {
                step = fromAscii <= toAscii ? 1 : -1
            }
            var out: [String] = []
            var value = fromAscii
            while step > 0 ? value <= toAscii : value >= toAscii {
                out.append(String(UnicodeScalar(UInt8(value))))
                value += step
            }
            return out
        }

        return nil
    }

    private static func splitOnDotDot(_ input: String) -> [String] {
        var parts: [String] = [""]
        let chars = Array(input)
        var idx = 0
        while idx < chars.count {
            if idx + 1 < chars.count, chars[idx] == ".", chars[idx + 1] == "." {
                parts.append("")
                idx += 2
            } else {
                parts[parts.count - 1].append(chars[idx])
                idx += 1
            }
        }
        return parts
    }

    /// Width to zero-pad to; 0 if neither endpoint had a leading zero.
    private static func zeroPad(_ input: String) -> Int {
        var trimmed = input
        if trimmed.first == "-" || trimmed.first == "+" { trimmed.removeFirst() }
        if trimmed.count > 1, trimmed.first == "0" { return input.count }
        return 0
    }

    private static func formatInt(_ value: Int, padTo: Int) -> String {
        guard padTo > 0 else { return String(value) }
        let sign = value < 0 ? "-" : ""
        let body = String(abs(value))
        let pad = max(0, padTo - body.count - sign.count)
        return sign + String(repeating: "0", count: pad) + body
    }
}
