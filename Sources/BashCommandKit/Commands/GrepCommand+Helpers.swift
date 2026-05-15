import Foundation

extension GrepCommand {

    // MARK: Match strategies

    /// Compiles the pattern once per command invocation and answers
    /// "does this line match?" for each input line.
    struct LineMatcher: Sendable {
        let invert: Bool
        let kind: LineMatcherKind

        init(pattern: String,
             extendedRegexp: Bool,
             ignoreCase: Bool,
             invert: Bool) throws {
            self.invert = invert
            if extendedRegexp {
                var opts: NSRegularExpression.Options = []
                if ignoreCase { opts.insert(.caseInsensitive) }
                self.kind = .regex(try NSRegularExpression(
                    pattern: pattern, options: opts))
            } else {
                self.kind = .substring(
                    needle: ignoreCase ? pattern.lowercased() : pattern,
                    ignoreCase: ignoreCase)
            }
        }

        func matches(_ line: String) -> Bool {
            let raw: Bool
            switch kind {
            case .substring(let needle, let caseInsensitive):
                let haystack = caseInsensitive ? line.lowercased() : line
                raw = haystack.contains(needle)
            case .regex(let regex):
                let range = NSRange(line.startIndex..., in: line)
                raw = regex.firstMatch(in: line, options: [], range: range) != nil
            }
            return invert ? !raw : raw
        }
    }

    /// Strategy for ``LineMatcher`` — hoisted out of the struct to keep
    /// nesting at one level.
    enum LineMatcherKind: Sendable {
        case substring(needle: String, ignoreCase: Bool)
        case regex(NSRegularExpression)
    }

    // MARK: Helpers

    /// Fixed-capacity FIFO ring buffer used for `-B` before-context.
    /// Iterating `elements` walks oldest → newest.
    struct RingBuffer<T> {
        private var storage: [T] = []
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            storage.reserveCapacity(max(capacity, 0))
        }

        mutating func push(_ element: T) {
            guard capacity > 0 else { return }
            if storage.count == capacity { storage.removeFirst() }
            storage.append(element)
        }

        var elements: [T] { storage }
    }

    // MARK: Glob matching for --include
    //
    // Same fnmatch-style matcher used elsewhere in BashCommandKit; the
    // public `BashInterpreter.GlobMatcher` is internal to that target.

    static func globMatch(pattern: String, string: String) -> Bool {
        let patChars = Array(pattern)
        let strChars = Array(string)
        return globMatch(patChars, 0, strChars, 0)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func globMatch(_ patChars: [Character], _ patStart: Int,
                                  _ strChars: [Character], _ strStart: Int) -> Bool {
        var patIdx = patStart
        var strIdx = strStart
        while patIdx < patChars.count {
            let char = patChars[patIdx]
            switch char {
            case "*":
                while patIdx < patChars.count, patChars[patIdx] == "*" { patIdx += 1 }
                if patIdx == patChars.count { return true }
                var probe = strIdx
                while probe <= strChars.count {
                    if globMatch(patChars, patIdx, strChars, probe) { return true }
                    probe += 1
                }
                return false
            case "?":
                if strIdx >= strChars.count { return false }
                patIdx += 1
                strIdx += 1
            case "\\":
                guard patIdx + 1 < patChars.count, strIdx < strChars.count,
                      patChars[patIdx + 1] == strChars[strIdx]
                else { return false }
                patIdx += 2
                strIdx += 1
            default:
                if strIdx >= strChars.count || strChars[strIdx] != char { return false }
                patIdx += 1
                strIdx += 1
            }
        }
        return strIdx == strChars.count
    }
}
