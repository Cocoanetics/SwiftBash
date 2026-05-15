import Foundation

// Per-operator helpers for bash parameter expansion: prefix/suffix
// strip, pattern replace, case conversion, substring/array slicing.
// Split out from `Shell+ParameterExpansion.swift` to keep both files
// within the file-length limit.

extension Shell {

    // MARK: Inner expansion for parameter-operator words

    // Expand the "word" portion of a parameter-form operator
    // (e.g. the `$(date)` in `${BAR:-$(date)}`) — same rules as
    // inside a double-quoted string. Implementation lives in
    // ``expandHeredocBody(_:)``; both contexts share semantics.
    func recursivelyExpandParameterWord(_ text: String) async throws -> String {
        try await expandHeredocBody(text)
    }

    // MARK: Prefix / suffix pattern operations

    // Returns `value` with the shortest or longest prefix matching
    // `pattern` removed; returns `value` unchanged if no prefix matches.
    func stripPrefix(_ value: String,
                     pattern: String,
                     longest: Bool) -> String {
        let chars = Array(value)
        let range = longest
            ? Array((0...chars.count).reversed())
            : Array(0...chars.count)
        for length in range {
            let prefix = String(chars.prefix(length))
            if GlobMatcher.match(pattern: pattern, string: prefix) {
                return String(chars.dropFirst(length))
            }
        }
        return value
    }

    // Returns `value` with the shortest or longest suffix matching
    // `pattern` removed.
    func stripSuffix(_ value: String,
                     pattern: String,
                     longest: Bool) -> String {
        let chars = Array(value)
        let range = longest
            ? Array((0...chars.count).reversed())
            : Array(0...chars.count)
        for length in range {
            let suffix = String(chars.suffix(length))
            if GlobMatcher.match(pattern: pattern, string: suffix) {
                return String(chars.dropLast(length))
            }
        }
        return value
    }

    // MARK: Replace

    func replace(in value: String,
                 pattern: String,
                 replacement: String,
                 all: Bool,
                 anchor: ParameterForm.ReplaceAnchor) -> String {
        let chars = Array(value)

        // Anchored variants only look at one position.
        switch anchor {
        case .start:
            if let len = longestMatch(of: pattern, in: chars, at: 0) {
                return replacement + String(chars.dropFirst(len))
            }
            return value
        case .end:
            for len in (0...chars.count).reversed() {
                let suffix = String(chars.suffix(len))
                if GlobMatcher.match(pattern: pattern, string: suffix) {
                    return String(chars.dropLast(len)) + replacement
                }
            }
            return value
        case .any:
            break
        }

        var result = ""
        var pos = 0
        while pos < chars.count {
            if let len = longestMatch(of: pattern, in: chars, at: pos), len > 0 {
                result.append(replacement)
                pos += len
                if !all {
                    result.append(String(chars[pos...]))
                    return result
                }
            } else {
                result.append(chars[pos])
                pos += 1
            }
        }
        return result
    }

    // MARK: Case conversion

    // Apply `${var^}` / `${var^^}` / `${var,}` / `${var,,}` semantics.
    // `pattern` empty means "every character matches".
    func applyCaseConvert(value: String,
                          toUpper: Bool,
                          all: Bool,
                          pattern: String) -> String {
        let effectivePattern = pattern.isEmpty ? "?" : pattern
        var out = ""
        var first = true
        for char in value {
            let matches = GlobMatcher.match(
                pattern: effectivePattern, string: String(char))
            let shouldConvert = matches && (all || first)
            if shouldConvert {
                out += toUpper ? String(char).uppercased()
                                : String(char).lowercased()
            } else {
                out.append(char)
            }
            first = false
        }
        return out
    }

    // The length of the longest prefix of `chars[start…]` that fully matches
    // `pattern` as a glob. Returns `nil` when no match exists.
    func longestMatch(of pattern: String,
                      in chars: [Character], at start: Int) -> Int? {
        let remaining = chars.count - start
        for len in (0...remaining).reversed() {
            let slice = String(chars[start..<start + len])
            if GlobMatcher.match(pattern: pattern, string: slice) {
                return len
            }
        }
        return nil
    }

    // MARK: Substring

    // Slice `array` per bash's `${arr[@]:offset[:length]}` rules:
    // negative `offset` indexes from the end; nil `length` is "all
    // remaining"; negative `length` truncates that many elements
    // from the end of the result.
    func sliceArray(_ array: [String],
                    offset: Int,
                    length: Int?) -> [String] {
        let count = array.count
        var start = offset < 0 ? max(0, count + offset) : min(offset, count)
        let end: Int
        switch length {
        case .none:
            end = count
        case .some(let len) where len >= 0:
            end = min(count, start + len)
        case .some(let len):
            end = max(start, count + len)
        }
        if end < start { return [] }
        start = min(start, end)
        return Array(array[start..<end])
    }

    func substring(of value: String, offset: Int, length: Int?) -> String {
        let chars = Array(value)
        let count = chars.count

        // Offset: negative means "from the end".
        var start = offset < 0 ? max(0, count + offset) : min(offset, count)

        let end: Int
        switch length {
        case .none:
            end = count
        case .some(let len) where len >= 0:
            end = min(count, start + len)
        case .some(let len):
            // Negative length: end that many chars from the end of the value.
            end = max(start, count + len)
        }
        if end < start { return "" }
        start = min(start, end)
        return String(chars[start..<end])
    }
}
