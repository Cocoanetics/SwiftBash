import Foundation

extension SedExecutor {

    struct SubstituteOptions {
        let pattern: String
        let replacement: String
        let global: Bool
        let ignoreCase: Bool
        let printOnMatch: Bool
        let nth: Int?
        let extendedRegex: Bool
        let writeFile: String?
    }

    // Two-pass scan: regex match collection + replacement expansion.
    // Splitting per-branch helpers wouldn't reduce the inherent loop
    // structure; the body is one cohesive substitution algorithm.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func applySubstitute(options: SubstituteOptions,
                         state: inout SedRunState) {
        var raw = options.pattern
        if raw.isEmpty, let last = state.lastPattern {
            raw = last
        } else if !raw.isEmpty {
            state.lastPattern = raw
        }
        guard let regex = try? SedRegex.compile(raw, extendedRegex: options.extendedRegex,
                                                ignoreCase: options.ignoreCase) else {
            return
        }
        let nsstr = state.patternSpace as NSString
        let fullRange = NSRange(location: 0, length: nsstr.length)
        let matches = regex.matches(in: state.patternSpace, range: fullRange)
        if matches.isEmpty { return }
        state.substitutionMade = true

        var result = ""
        var pos = 0
        var matchCount = 0
        var didReplace = false
        for match in matches {
            matchCount += 1
            // Append the unmatched gap.
            if match.range.location > pos {
                result += nsstr.substring(with: NSRange(location: pos, length: match.range.location - pos))
            }
            let shouldReplace: Bool
            if let nth = options.nth, !options.global {
                shouldReplace = matchCount == nth
            } else if !options.global && didReplace {
                shouldReplace = false
            } else {
                shouldReplace = true
            }
            if shouldReplace {
                let replaced = expandReplacement(options.replacement, match: match, in: state.patternSpace)
                result += replaced
                didReplace = true
            } else {
                result += nsstr.substring(with: match.range)
            }
            pos = match.range.location + match.range.length
            if !options.global, didReplace, options.nth == nil { break }
        }
        // Tail
        if pos < nsstr.length {
            result += nsstr.substring(from: pos)
        }
        state.patternSpace = result
        if options.printOnMatch {
            state.lineNumberOutput.append(state.patternSpace)
        }
        if let writeFile = options.writeFile {
            state.pendingFileWrites.append(.init(filename: writeFile, content: state.patternSpace + "\n"))
        }
    }

    // Expand sed's replacement syntax into the literal output:
    // `&` and `\0` → whole match, `\1`..`\9` → groups, `\n/\t/\r`
    // → control chars, `\\` → `\`, other `\X` → `X`.
    // Replacement expansion: backslash-escape dispatch table (one char
    // each for &, n, t, r, \, digits 0-9). Each `if` is a tiny one-line
    // case; pulling them apart would just scatter the table.
    // swiftlint:disable:next cyclomatic_complexity
    func expandReplacement(_ rep: String, match: NSTextCheckingResult, in source: String) -> String {
        let nsstr = source as NSString
        var out = ""
        let chars = Array(rep)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                if next == "&" { out += "&"; index += 2; continue }
                if next == "n" { out += "\n"; index += 2; continue }
                if next == "t" { out += "\t"; index += 2; continue }
                if next == "r" { out += "\r"; index += 2; continue }
                if next == "\\" { out += "\\"; index += 2; continue }
                if let digit = next.asciiValue, digit >= 0x30, digit <= 0x39 {
                    let idx = Int(digit - 0x30)
                    if idx == 0 {
                        out += nsstr.substring(with: match.range)
                    } else if idx < match.numberOfRanges {
                        let groupRange = match.range(at: idx)
                        if groupRange.location != NSNotFound {
                            out += nsstr.substring(with: groupRange)
                        }
                    }
                    index += 2
                    continue
                }
                out.append(next); index += 2; continue
            }
            if char == "&" {
                out += nsstr.substring(with: match.range); index += 1; continue
            }
            out.append(char); index += 1
        }
        return out
    }
}
