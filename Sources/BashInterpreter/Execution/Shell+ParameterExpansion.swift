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
        let form = try await expandingSubscripts(in: form)
        switch form {
        case .plain(let name):
            return lookup(name)

        case .length(let name):
            // `${#arr[@]}` / `${#arr[*]}` returns element COUNT, not
            // the joined string's character length.
            if let (arrName, sub) = parseSubscriptedName(name),
               sub == "@" || sub == "*"
            {
                if let assoc = environment.associativeArrays[arrName] {
                    return String(assoc.count)
                }
                return String(environment.arrays[arrName]?.count ?? 0)
            }
            return String(lookup(name).count)

        case .defaultValue(let name, let checkEmpty, let value):
            let raw = lookupOptional(name)
            if isMissing(raw, checkEmpty: checkEmpty) {
                return try await recursivelyExpand(value)
            }
            return raw ?? ""

        case .assignDefault(let name, let checkEmpty, let value):
            let raw = lookupOptional(name)
            if isMissing(raw, checkEmpty: checkEmpty) {
                let expanded = try await recursivelyExpand(value)
                environment[name] = expanded
                return expanded
            }
            return raw ?? ""

        case .errorIfUnset(let name, let checkEmpty, let message):
            let raw = lookupOptional(name)
            if isMissing(raw, checkEmpty: checkEmpty) {
                let msg = message.isEmpty
                    ? "parameter null or not set"
                    : try await recursivelyExpand(message)
                // Match bash: write `script:line: var: msg` to stderr,
                // then exit with status 1. Inside a subshell the
                // existing `ShellExit` catch in `executeSubshellGroup`
                // turns the throw into the subshell's `$?`.
                stderr("\(errorLocationPrefix())\(name): \(msg)\n")
                throw ShellExit(status: ExitStatus(1))
            }
            return raw ?? ""

        case .alternative(let name, let checkEmpty, let value):
            let raw = lookupOptional(name)
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
                let elements = environment.arrays[arrName]?.elementsInOrder ?? []
                let sliced = sliceArray(elements, offset: offset, length: length)
                let sep = sub == "*"
                    ? String(environment["IFS"]?.first ?? " ")
                    : " "
                return sliced.joined(separator: sep)
            }
            return substring(of: lookup(name), offset: offset, length: length)

        case .indirect(let name):
            // `${!ref}` — read `ref`'s value, then look that up as a
            // parameter name. Common idiom for poor-man's nameref.
            let target = lookup(name)
            if target.isEmpty { return "" }
            return lookup(target)

        case .caseConvert(let name, let toUpper, let all, let pattern):
            return applyCaseConvert(value: lookup(name),
                                    toUpper: toUpper,
                                    all: all,
                                    pattern: pattern)

        case .indices(let name):
            // `${!arr[@]}` / `${!arr[*]}` — for indexed arrays, the
            // sorted list of *set* indices. For associative arrays,
            // the list of keys (order is dictionary-order, not
            // strictly sorted, since bash makes no guarantee here).
            if let (arrName, _) = parseSubscriptedName(name) {
                if let assoc = environment.associativeArrays[arrName] {
                    return assoc.keys.joined(separator: " ")
                }
                if let array = environment.arrays[arrName] {
                    return array.sortedIndices
                        .map(String.init)
                        .joined(separator: " ")
                }
            }
            return ""
        }
    }

    // MARK: Lookup helper

    /// Optional-returning sibling of ``lookup(_:)`` that distinguishes
    /// "unset" (`nil`) from "set but empty" (`""`). Used by the
    /// `${var:-default}`, `${var:=default}`, `${var:+alt}`, and
    /// `${var:?msg}` forms — they need that distinction to decide
    /// whether to substitute / assign / error.
    ///
    /// Without this routine those forms would call `environment[name]`
    /// directly, which only consults the *named* variables map and
    /// silently skips positional parameters: `${1:-fallback}` would
    /// always evaluate to `fallback` even when `$1` is set, because
    /// `environment["1"]` is `nil`. Routing through here closes that
    /// bug.
    private func lookupOptional(_ name: String) -> String? {
        // Special parameters — `$?` `$$` `$#` `$@` `$*` `$0` are
        // always "set", and digit-only names are positional params.
        switch name {
        case "?": return "\(lastExitStatus.code)"
        case "$": return "\(virtualPID)"
        case "#": return "\(positionalParameters.count)"
        case "0": return scriptName
        case "@", "*":
            // Same join behaviour as `lookup` — we don't have IFS here
            // because the caller (parameter expansion) handles word-
            // splitting separately. Always-set: empty array still
            // returns "" (set), not nil (unset).
            return positionalParameters.joined(separator: " ")
        default:
            break
        }
        if !name.isEmpty, name.allSatisfy(\.isNumber),
           let n = Int(name), n >= 1
        {
            let idx = n - 1
            return idx < positionalParameters.count
                ? positionalParameters[idx]
                : nil
        }
        // Indexed-array reference falls through to lookup() — arrays
        // never appear as `${arr[0]:-…}` against unset vs. empty in a
        // way the regular environment subscript can't already answer
        // (`environment[name]` for `arr[0]` is the element value or
        // nil if unset).
        return environment[name]
    }

    private func lookup(_ name: String) -> String {
        // Special parameters first.
        switch name {
        case "?": return "\(lastExitStatus.code)"
        case "$": return "\(virtualPID)"
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

    /// Pre-expand any `$var` / `${...}` / `$(cmd)` / `$((expr))` /
    /// backticks inside an array subscript. `${arr[$k]}` becomes
    /// `${arr[<value-of-k>]}` before the form is dispatched.
    /// `[@]` and `[*]` are passed through unchanged. Names without
    /// subscripts are returned as-is.
    private func expandingSubscripts(in form: ParameterForm)
        async throws -> ParameterForm
    {
        switch form {
        case .plain(let name):
            return .plain(try await expandedSubscript(in: name))
        case .length(let name):
            return .length(try await expandedSubscript(in: name))
        case .indices(let name):
            return .indices(try await expandedSubscript(in: name))
        case .defaultValue(let name, let ce, let v):
            return .defaultValue(name: try await expandedSubscript(in: name),
                                 checkEmpty: ce, value: v)
        case .assignDefault(let name, let ce, let v):
            return .assignDefault(name: try await expandedSubscript(in: name),
                                  checkEmpty: ce, value: v)
        case .errorIfUnset(let name, let ce, let m):
            return .errorIfUnset(name: try await expandedSubscript(in: name),
                                 checkEmpty: ce, message: m)
        case .alternative(let name, let ce, let v):
            return .alternative(name: try await expandedSubscript(in: name),
                                checkEmpty: ce, value: v)
        case .removePrefix(let name, let p, let l):
            return .removePrefix(
                name: try await expandedSubscript(in: name),
                pattern: p, longest: l)
        case .removeSuffix(let name, let p, let l):
            return .removeSuffix(
                name: try await expandedSubscript(in: name),
                pattern: p, longest: l)
        case .replace(let name, let p, let r, let all, let a):
            return .replace(name: try await expandedSubscript(in: name),
                            pattern: p, replacement: r,
                            all: all, anchor: a)
        case .substring(let name, let o, let l):
            return .substring(name: try await expandedSubscript(in: name),
                              offset: o, length: l)
        case .indirect(let name):
            return .indirect(try await expandedSubscript(in: name))
        case .caseConvert(let name, let u, let all, let pat):
            return .caseConvert(
                name: try await expandedSubscript(in: name),
                toUpper: u, all: all, pattern: pat)
        }
    }

    private func expandedSubscript(in name: String) async throws -> String {
        guard let (head, sub) = parseSubscriptedName(name),
              sub != "@", sub != "*"
        else { return name }
        let expanded = try await expandHeredocBody(sub)
        return "\(head)[\(expanded)]"
    }

    /// Resolve a subscripted array reference.
    ///
    /// - Associative array (`declare -A`): subscript is a string key.
    /// - Indexed array: `${arr[N]}` returns the Nth element (empty
    ///   for unset slots), `${arr[@]}` / `${arr[*]}` join set elements
    ///   in index order.
    private func arrayElementLookup(_ name: String,
                                    `subscript` sub: String) -> String {
        if let assoc = environment.associativeArrays[name] {
            switch sub {
            case "@", "*":
                return assoc.values.joined(separator: " ")
            default:
                return assoc[sub] ?? ""
            }
        }
        if let array = environment.arrays[name] {
            switch sub {
            case "@", "*":
                return array.elementsInOrder.joined(separator: " ")
            default:
                if let n = Int(sub) {
                    // Bash 4.3+: negative indices count from the end of
                    // the *highest* set slot, not from `count`. So for
                    // `arr[0]=a; arr[5]=b`, `${arr[-1]}` is `b` (the
                    // value at index 5, not index 4).
                    let resolved = n >= 0 ? n
                        : ((array.entries.keys.max() ?? -1) + 1 + n)
                    return array[resolved] ?? ""
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

    // MARK: Case conversion

    /// Apply `${var^}` / `${var^^}` / `${var,}` / `${var,,}` semantics.
    /// `pattern` empty means "every character matches".
    func applyCaseConvert(value: String,
                          toUpper: Bool,
                          all: Bool,
                          pattern: String) -> String
    {
        let effectivePattern = pattern.isEmpty ? "?" : pattern
        var out = ""
        var first = true
        for ch in value {
            let matches = GlobMatcher.match(
                pattern: effectivePattern, string: String(ch))
            let shouldConvert = matches && (all || first)
            if shouldConvert {
                out += toUpper ? String(ch).uppercased()
                                : String(ch).lowercased()
            } else {
                out.append(ch)
            }
            first = false
        }
        return out
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
