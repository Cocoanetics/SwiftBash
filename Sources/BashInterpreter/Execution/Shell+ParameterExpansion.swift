import Foundation

extension Shell {

    // Evaluate a parsed ``ParameterForm`` against this shell's environment,
    // returning the resulting string.
    //
    // Default / alternative / error messages may themselves contain `$var`
    // or `${var}` references, which are re-expanded via a simple inner pass.
    // Command substitutions and arithmetic inside parameter bodies are NOT
    // yet supported.
    //
    // Each bash parameter-form variant has its own arm, so this switch is
    // intrinsically wide; per-form helpers would lose the inline state.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func applyParameterForm(_ form: ParameterForm) async throws -> String {
        let form = try await expandingSubscripts(in: form)
        switch form {
        case .plain(let name):
            // `set -u` / `set -o nounset` — bare `$var` or `${var}`
            // on a truly-unset name is an error. Default-form
            // expansions (`${var:-…}`, `${var:?…}`, etc.) get their
            // own cases below and handle unset explicitly, so this
            // only catches the bare-reference path. Match the
            // `${var:?…}` error shape — stderr + ShellExit — so the
            // status propagates the same way through subshells.
            if nounset, lookupOptional(name) == nil {
                stderr("\(errorLocationPrefix())\(name): unbound variable\n")
                throw ShellExit(status: ExitStatus(1))
            }
            return lookup(name)

        case .length(let name):
            if nounset, lookupOptional(name) == nil,
               // `${#arr[@]}` always answers 0 rather than erroring
               // even when the array is unset — matches real bash.
               !(parseSubscriptedName(name).map { $0.1 == "@" || $0.1 == "*" } ?? false) {
                stderr("\(errorLocationPrefix())\(name): unbound variable\n")
                throw ShellExit(status: ExitStatus(1))
            }
            // `${#arr[@]}` / `${#arr[*]}` returns element COUNT, not
            // the joined string's character length.
            if let (arrName, sub) = parseSubscriptedName(name),
               sub == "@" || sub == "*" {
                if let assoc = environment.associativeArrays[arrName] {
                    return String(assoc.count)
                }
                return String(environment.arrays[arrName]?.count ?? 0)
            }
            return String(lookup(name).count)

        case .defaultValue(let name, let checkEmpty, let value):
            let raw = lookupOptional(name)
            if isMissing(raw, checkEmpty: checkEmpty) {
                return try await recursivelyExpandParameterWord(value)
            }
            return raw ?? ""

        case .assignDefault(let name, let checkEmpty, let value):
            let raw = lookupOptional(name)
            if isMissing(raw, checkEmpty: checkEmpty) {
                let expanded = try await recursivelyExpandParameterWord(value)
                environment[name] = expanded
                return expanded
            }
            return raw ?? ""

        case .errorIfUnset(let name, let checkEmpty, let message):
            let raw = lookupOptional(name)
            if isMissing(raw, checkEmpty: checkEmpty) {
                let msg = message.isEmpty
                    ? "parameter null or not set"
                    : try await recursivelyExpandParameterWord(message)
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
            return try await recursivelyExpandParameterWord(value)

        case .removePrefix(let name, let pattern, let longest):
            return stripPrefix(lookup(name),
                               pattern: pattern,
                               longest: longest)

        case .removeSuffix(let name, let pattern, let longest):
            return stripSuffix(lookup(name),
                               pattern: pattern,
                               longest: longest)

        case .replace(let name, let pattern, let replacement, let all, let anchor):
            let expandedRepl = try await recursivelyExpandParameterWord(replacement)
            return replace(in: lookup(name),
                           pattern: pattern,
                           replacement: expandedRepl,
                           all: all,
                           anchor: anchor)

        case .substring(let name, let offsetExpr, let lengthExpr):
            // `${arr[@]:offset:length}` / `${arr[*]:offset:length}` —
            // element-wise slice, joined with a space (or with IFS
            // first char for the `*` form). Other subscript forms
            // (`arr[0]:1:2`) and bare scalars use the regular
            // character-substring semantics. Offset and length are
            // arithmetic expressions (bash spec) — evaluate them now
            // so `$i` / `i+1` / `$#name` all work.
            //
            // Arithmetic evaluation errors (bad token, divide by
            // zero, …) are reported the way bash reports them: a
            // diagnostic on stderr plus `ShellExit(1)` so the run
            // boundary catches it and surfaces $? = 1. Without
            // this catch the underlying `ArithError` would bubble
            // out as a Swift `Error`, which the embedder sees as
            // an opaque thrown error instead of a graceful failure.
            let offset: Int
            let length: Int?
            do {
                offset = Int(try await evaluateArithmetic(offsetExpr))
                if let lengthExpr {
                    length = Int(try await evaluateArithmetic(lengthExpr))
                } else {
                    length = nil
                }
            } catch {
                let failed = lengthExpr.flatMap { _ in
                    // Best-effort: report the offset by default;
                    // the lexer doesn't tell us which sub-field
                    // failed, but the offset is the more common
                    // culprit and matches bash's diagnostic shape.
                    offsetExpr
                } ?? offsetExpr
                let trimmed = failed.trimmingCharacters(in: .whitespaces)
                stderr("\(errorLocationPrefix())\(trimmed): "
                       + "syntax error: invalid arithmetic expression\n")
                throw ShellExit(status: ExitStatus(1))
            }
            if let (arrName, sub) = parseSubscriptedName(name),
               sub == "@" || sub == "*" {
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
           let number = Int(name), number >= 1 {
            let idx = number - 1
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
           let number = Int(name), number >= 1 {
            let idx = number - 1
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
        guard let leftBracket = name.firstIndex(of: "["), name.last == "]" else {
            return nil
        }
        let head = String(name[..<leftBracket])
        let after = name.index(after: leftBracket)
        let last = name.index(before: name.endIndex)
        guard after <= last else { return nil }
        let sub = String(name[after..<last])
        return (head, sub)
    }

    // Pre-expand any `$var` / `${...}` / `$(cmd)` / `$((expr))` /
    // backticks inside an array subscript. `${arr[$k]}` becomes
    // `${arr[<value-of-k>]}` before the form is dispatched.
    // `[@]` and `[*]` are passed through unchanged. Names without
    // subscripts are returned as-is.
    // Per-variant rewrap of the ParameterForm enum; the wide switch is
    // intrinsic to the data model.
    // swiftlint:disable:next cyclomatic_complexity
    private func expandingSubscripts(in form: ParameterForm)
        async throws -> ParameterForm {
        switch form {
        case .plain(let name):
            return .plain(try await expandedSubscript(in: name))
        case .length(let name):
            return .length(try await expandedSubscript(in: name))
        case .indices(let name):
            return .indices(try await expandedSubscript(in: name))
        case .defaultValue(let name, let checkEmpty, let value):
            return .defaultValue(name: try await expandedSubscript(in: name),
                                 checkEmpty: checkEmpty, value: value)
        case .assignDefault(let name, let checkEmpty, let value):
            return .assignDefault(name: try await expandedSubscript(in: name),
                                  checkEmpty: checkEmpty, value: value)
        case .errorIfUnset(let name, let checkEmpty, let message):
            return .errorIfUnset(name: try await expandedSubscript(in: name),
                                 checkEmpty: checkEmpty, message: message)
        case .alternative(let name, let checkEmpty, let value):
            return .alternative(name: try await expandedSubscript(in: name),
                                checkEmpty: checkEmpty, value: value)
        case .removePrefix(let name, let pattern, let longest):
            return .removePrefix(
                name: try await expandedSubscript(in: name),
                pattern: pattern, longest: longest)
        case .removeSuffix(let name, let pattern, let longest):
            return .removeSuffix(
                name: try await expandedSubscript(in: name),
                pattern: pattern, longest: longest)
        case .replace(let name, let pattern, let replacement, let all, let anchor):
            return .replace(name: try await expandedSubscript(in: name),
                            pattern: pattern, replacement: replacement,
                            all: all, anchor: anchor)
        case .substring(let name, let offsetExpr, let lengthExpr):
            return .substring(name: try await expandedSubscript(in: name),
                              offset: offsetExpr, length: lengthExpr)
        case .indirect(let name):
            return .indirect(try await expandedSubscript(in: name))
        case .caseConvert(let name, let toUpper, let all, let pattern):
            return .caseConvert(
                name: try await expandedSubscript(in: name),
                toUpper: toUpper, all: all, pattern: pattern)
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
                if let index = Int(sub) {
                    // Bash 4.3+: negative indices count from the end of
                    // the *highest* set slot, not from `count`. So for
                    // `arr[0]=a; arr[5]=b`, `${arr[-1]}` is `b` (the
                    // value at index 5, not index 4).
                    let resolved = index >= 0 ? index
                        : ((array.entries.keys.max() ?? -1) + 1 + index)
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

}
