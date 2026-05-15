import Foundation
import BashSyntax

extension Shell {

    /// Brace-expand `args` only when the *source* of `node` contains an
    /// unquoted brace pattern. This guards against expanding braces that
    /// arrived inside quoted JSON / regex literals where bash would not
    /// expand them either.
    func braceExpandIfWordHasUnquotedBraces(
        node: Node, args: [String]
    ) -> [String] {
        let chars = Array(currentSource)
        let low = max(0, node.range.lowerBound)
        let high = min(chars.count, node.range.upperBound)
        guard low < high else { return args }
        guard hasUnquotedBracePattern(chars, low: low, high: high) else {
            return args
        }
        return args.flatMap { BraceExpansion.expand($0) }
    }

    // State machine over quote/brace nesting; flattening the loop into
    // smaller helpers would obscure the depth/quote/delim coupling.
    // swiftlint:disable:next cyclomatic_complexity
    private func hasUnquotedBracePattern(_ chars: [Character],
                                         low: Int, high: Int) -> Bool {
        var index = low
        var inSingle = false
        var inDouble = false
        var braceStart: Int?
        var sawDelim = false
        var depth = 0
        while index < high {
            let char = chars[index]
            if char == "\\", index + 1 < high {
                index += 2; continue
            }
            if !inDouble, char == "'" { inSingle.toggle(); index += 1; continue }
            if !inSingle, char == "\"" { inDouble.toggle(); index += 1; continue }
            if inSingle || inDouble {
                index += 1; continue
            }
            if char == "{" {
                if depth == 0 { braceStart = index; sawDelim = false }
                depth += 1
            } else if char == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, braceStart != nil, sawDelim {
                        return true
                    }
                }
            } else if depth == 1 {
                // A top-level comma, or `..` between braces, qualifies
                // the pair as a brace expansion candidate.
                if char == "," {
                    sawDelim = true
                } else if char == ".", index + 1 < high, chars[index + 1] == "." {
                    sawDelim = true
                }
            }
            index += 1
        }
        return false
    }
}
