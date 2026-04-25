import Foundation

extension Shell {

    /// Evaluate a parsed ``ParameterForm`` against this shell's environment,
    /// returning the resulting string.
    ///
    /// Default / alternative / error messages may themselves contain
    /// `$var` or `${var}` references, which are re-expanded via a simple
    /// inner pass. Command substitutions and arithmetic inside parameter
    /// bodies are NOT yet supported.
    func applyParameterForm(_ form: ParameterForm) async throws -> String {
        switch form {
        case .plain(let name):
            return lookup(name)

        case .length(let name):
            // `${#arr[@]}` / `${#arr[*]}` returns element COUNT, not
            // the joined string's character length.
            if let (arrName, sub) = parseSubscriptedName(name),
               sub == "@" || sub == "*"
            {
                return String(environment.arrays[arrName]?.count ?? 0)
            }
            return String(lookup(name).count)

        case .defaultValue(let name, let checkEmpty, let value):
            let raw = environment[name]
            if isMissing(raw, checkEmpty: checkEmpty) {
                return try await recursivelyExpand(value)
            }
            return raw ?? ""

        case .assignDefault(let name, let checkEmpty, let value):
            let raw = environment[name]
            if isMissing(raw, checkEmpty: checkEmpty) {
                let expanded = try await recursivelyExpand(value)
                environment[name] = expanded
                return expanded
            }
            return raw ?? ""

        case .errorIfUnset(let name, let checkEmpty, let message):
            let raw = environment[name]
            if isMissing(raw, checkEmpty: checkEmpty) {
                let msg = message.isEmpty
                    ? "parameter null or not set"
                    : try await recursivelyExpand(message)
                throw BashInterpreterError.parameter("\(name): \(msg)")
            }
            return raw ?? ""

        case .alternative(let name, let checkEmpty, let value):
            let raw = environment[name]
            if isMissing(raw, checkEmpty: checkEmpty) {
                return ""
            }
            return try await recursivelyExpand(value)

        case .removePrefix(let name, let pattern, let longest):
            return stripPrefix(lookup(name),
                               pattern: pattern,
                               longest: longest)

        case .removeSuffix(let name, let pattern, let longest):
            return stripSuffix(lookup(name),
                               pattern: pattern,
                               longest: longest)

        case .replace(let name, let pattern, let replacement, let all, let anchor):
            let expandedRepl = try await recursivelyExpand(replacement)
            return replace(in: lookup(name),
                           pattern: pattern,
                           replacement: expandedRepl,
                           all: all,
                           anchor: anchor)

        case .substring(let name, let offset, let length):
            // `${arr[@]:offset:length}` / `${arr[*]:offset:length}` —
            // element-wise slice, joined with a space (or with IFS
            // first char for the `*` form). Other subscript forms
            // (`arr[0]:1:2`) and bare scalars use the regular
            // character-substring semantics.
            if let (arrName, sub) = parseSubscriptedName(name),
               sub == "@" || sub == "*"
            {
                let array = environment.arrays[arrName] ?? []
                let sliced = sliceArray(array, offset: offset, length: length)
                let sep = sub == "*"
                    ? String(environment["IFS"]?.first ?? " ")
                    : " "
                return sliced.joined(separator: sep)
            }
            return substring(of: lookup(name), offset: offset, length: length)
        }
    }

    // MARK: Lookup helper

    private func lookup(_ name: String) -> String {
        // Special parameters first.
        switch name {
        case "?": return "\(lastExitStatus.code)"
        case "$": return "\(getpid())"
        case "#": return "\(positionalParameters.count)"
        case "0": return scriptName
        case "@", "*":
            return positionalParameters.joined(separator: " ")
        default:
            break
        }
        // Digit-only names address positional parameters
        // (`${1}`, `${10}`, length-of `${#10}`, etc.).
        if !name.isEmpty, name.allSatisfy(\.isNumber),
           let n = Int(name), n >= 1
        {
            let idx = n - 1
            return idx < positionalParameters.count
                ? positionalParameters[idx]
                : ""
        }
        // Indexed-array reference: `arr[0]`, `arr[1]`, `arr[@]`, `arr[*]`.
        if let (arrName, sub) = parseSubscriptedName(name) {
            return arrayElementLookup(arrName, subscript: sub)
        }
        return environment[name] ?? ""
    }

    /// Split `arr[sub]` into `("arr", "sub")`. Returns `nil` if
    /// `name` isn't a subscripted form.
    private func parseSubscriptedName(_ name: String) -> (String, String)? {
        guard let lb = name.firstIndex(of: "["), name.last == "]" else {
            return nil
        }
        let head = String(name[..<lb])
        let after = name.index(after: lb)
        let last = name.index(before: name.endIndex)
        guard after <= last else { return nil }
        let sub = String(name[after..<last])
        return (head, sub)
    }

    /// Resolve a subscripted array reference. `${arr[N]}` returns the
    /// Nth element; `${arr[@]}` / `${arr[*]}` join all elements with
    /// a space. The argv-level expander gets a separate path for the
    /// proper boundary-merge / per-element semantics of `"${arr[@]}"`.
    private func arrayElementLookup(_ name: String,
                                    `subscript` sub: String) -> String {
        if let array = environment.arrays[name] {
            switch sub {
            case "@", "*":
                return array.joined(separator: " ")
            default:
                if let n = Int(sub), n >= 0, n < array.count {
                    return array[n]
                }
                return ""
            }
        }
        // Scalar fallback: `${name[0]}` reads the scalar value at
        // index 0; everything else is empty.
        if sub == "0" || sub == "@" || sub == "*" {
            return environment.variables[name] ?? ""
        }
        return ""
    }

    private func isMissing(_ raw: String?, checkEmpty: Bool) -> Bool {
        if raw == nil { return true }
        if checkEmpty, raw == "" { return true }
        return false
    }

    // MARK: Inner expansion for parameter-operator words

    /// Expand the "word" portion of a parameter-form operator
    /// (e.g. the `$(date)` in `${BAR:-$(date)}`) — same rules as
    /// inside a double-quoted string. Implementation lives in
    /// ``expandHeredocBody(_:)``; both contexts share semantics.
    private func recursivelyExpand(_ s: String) async throws -> String {
        try await expandHeredocBody(s)
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

    /// Slice `array` per bash's `${arr[@]:offset[:length]}` rules:
    /// negative `offset` indexes from the end; nil `length` is "all
    /// remaining"; negative `length` truncates that many elements
    /// from the end of the result.
    private func sliceArray(_ array: [String],
                            offset: Int,
                            length: Int?) -> [String] {
        let n = array.count
        var start = offset < 0 ? max(0, n + offset) : min(offset, n)
        let end: Int
        switch length {
        case .none:
            end = n
        case .some(let len) where len >= 0:
            end = min(n, start + len)
        case .some(let len):
            end = max(start, n + len)
        }
        if end < start { return [] }
        start = min(start, end)
        return Array(array[start..<end])
    }

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
