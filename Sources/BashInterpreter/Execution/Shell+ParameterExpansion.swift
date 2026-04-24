import Foundation

extension Shell {

    /// Evaluate a parsed ``ParameterForm`` against this shell's environment,
    /// returning the resulting string.
    ///
    /// Default / alternative / error messages may themselves contain
    /// `$var` or `${var}` references, which are re-expanded via a simple
    /// inner pass. Command substitutions and arithmetic inside parameter
    /// bodies are NOT yet supported.
    func applyParameterForm(_ form: ParameterForm) throws -> String {
        switch form {
        case .plain(let name):
            return lookup(name)

        case .length(let name):
            return String(lookup(name).count)

        case .defaultValue(let name, let checkEmpty, let value):
            let raw = environment[name]
            if isMissing(raw, checkEmpty: checkEmpty) {
                return try recursivelyExpand(value)
            }
            return raw ?? ""

        case .assignDefault(let name, let checkEmpty, let value):
            let raw = environment[name]
            if isMissing(raw, checkEmpty: checkEmpty) {
                let expanded = try recursivelyExpand(value)
                environment[name] = expanded
                return expanded
            }
            return raw ?? ""

        case .errorIfUnset(let name, let checkEmpty, let message):
            let raw = environment[name]
            if isMissing(raw, checkEmpty: checkEmpty) {
                let msg = message.isEmpty
                    ? "parameter null or not set"
                    : try recursivelyExpand(message)
                throw BashInterpreterError.parameter("\(name): \(msg)")
            }
            return raw ?? ""

        case .alternative(let name, let checkEmpty, let value):
            let raw = environment[name]
            if isMissing(raw, checkEmpty: checkEmpty) {
                return ""
            }
            return try recursivelyExpand(value)

        case .removePrefix(let name, let pattern, let longest):
            return stripPrefix(lookup(name),
                               pattern: pattern,
                               longest: longest)

        case .removeSuffix(let name, let pattern, let longest):
            return stripSuffix(lookup(name),
                               pattern: pattern,
                               longest: longest)

        case .replace(let name, let pattern, let replacement, let all, let anchor):
            let expandedRepl = try recursivelyExpand(replacement)
            return replace(in: lookup(name),
                           pattern: pattern,
                           replacement: expandedRepl,
                           all: all,
                           anchor: anchor)

        case .substring(let name, let offset, let length):
            return substring(of: lookup(name), offset: offset, length: length)
        }
    }

    // MARK: Lookup helper

    private func lookup(_ name: String) -> String {
        // Special single-char parameters handled by the existing
        // resolveParameter; for everything else, raw value or empty.
        switch name {
        case "?": return "\(lastExitStatus.code)"
        case "$": return "\(getpid())"
        case "#": return "0"
        case "0": return "swift-bash"
        default:
            return environment[name] ?? ""
        }
    }

    private func isMissing(_ raw: String?, checkEmpty: Bool) -> Bool {
        if raw == nil { return true }
        if checkEmpty, raw == "" { return true }
        return false
    }

    // MARK: Inner $var / ${name} expansion for default values

    /// Lightweight expander used for the "word" inside parameter
    /// operators (e.g. the `$FOO` in `${BAR:-$FOO}`). Supports `$name`
    /// and `${body}` only — no command substitution or arithmetic.
    private func recursivelyExpand(_ s: String) throws -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "$", i + 1 < chars.count {
                if chars[i + 1] == "{" {
                    // Find matching `}` (no nesting support).
                    var j = i + 2
                    var body = ""
                    while j < chars.count, chars[j] != "}" {
                        body.append(chars[j])
                        j += 1
                    }
                    if j < chars.count { j += 1 } // consume `}`
                    let form = (try? ParameterFormParser.parse(body)) ?? .plain(body)
                    out.append(try applyParameterForm(form))
                    i = j
                    continue
                }
                if chars[i + 1].isLetter || chars[i + 1] == "_" {
                    var j = i + 1
                    var name = ""
                    while j < chars.count,
                          chars[j].isLetter || chars[j].isNumber || chars[j] == "_"
                    {
                        name.append(chars[j])
                        j += 1
                    }
                    out.append(lookup(name))
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    // MARK: Prefix / suffix pattern operations

    /// Returns `value` with the shortest or longest prefix matching
    /// `pattern` removed; returns `value` unchanged if no prefix matches.
    private func stripPrefix(_ value: String,
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

    /// Returns `value` with the shortest or longest suffix matching
    /// `pattern` removed.
    private func stripSuffix(_ value: String,
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

    private func replace(in value: String,
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
        var i = 0
        while i < chars.count {
            if let len = longestMatch(of: pattern, in: chars, at: i), len > 0 {
                result.append(replacement)
                i += len
                if !all {
                    result.append(String(chars[i...]))
                    return result
                }
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    /// The length of the longest prefix of `chars[i…]` that fully matches
    /// `pattern` as a glob. Returns `nil` when no match exists.
    private func longestMatch(of pattern: String,
                              in chars: [Character], at i: Int) -> Int? {
        let remaining = chars.count - i
        for len in (0...remaining).reversed() {
            let slice = String(chars[i..<i + len])
            if GlobMatcher.match(pattern: pattern, string: slice) {
                return len
            }
        }
        return nil
    }

    // MARK: Substring

    private func substring(of value: String, offset: Int, length: Int?) -> String {
        let chars = Array(value)
        let n = chars.count

        // Offset: negative means "from the end".
        var start = offset < 0 ? max(0, n + offset) : min(offset, n)

        let end: Int
        switch length {
        case .none:
            end = n
        case .some(let len) where len >= 0:
            end = min(n, start + len)
        case .some(let len):
            // Negative length: end that many chars from the end of the value.
            end = max(start, n + len)
        }
        if end < start { return "" }
        start = min(start, end)
        return String(chars[start..<end])
    }
}
