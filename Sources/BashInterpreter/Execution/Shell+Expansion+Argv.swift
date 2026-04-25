import Foundation
import BashSyntax

extension Shell {

    /// Expand a word for argv position, returning the list of args
    /// (zero or more) the word produces. Combines fragment collection
    /// (parameter / command / arithmetic substitution) with field
    /// splitting and gives back the final arg list.
    ///
    /// Highlights:
    /// - `"$@"` expands to one arg per positional parameter, with
    ///   the first/last params merging into surrounding text in the
    ///   same word: `"prefix$@suffix"` with `[a, b, c]` →
    ///   `["prefixa", "b", "csuffix"]`.
    /// - Unquoted `$VAR` and `$(cmd)` are split on `$IFS` (default:
    ///   space, tab, newline). Empty results contribute zero args.
    /// - `""` and `''` produce one empty arg, but `"$UNSET"` and
    ///   `"$@"` (with no positional params) produce zero args — the
    ///   substitution simply disappears.
    /// - `"$*"` joins all positional params with the first `IFS`
    ///   character into a single arg.
    ///
    /// **Ordering note:** `executeSimpleCommand` *does not* call this
    /// directly. Bash mandates that prefix assignments (`IFS=":" cmd`)
    /// affect *field splitting* but not the *substitution* of vars in
    /// the same line. To honour that, the executor calls
    /// ``collectArgFragments(word:)`` first (with the old env), then
    /// applies the prefix assignments, then calls ``assembleArgs(_:)``
    /// (with the scoped IFS). This entry point is for callers that
    /// don't need that two-phase split (notably the `for VAR in …`
    /// clause).
    func expandToArgs(word node: Node) async throws -> [String] {
        let fragments = try await collectArgFragments(word: node)
        return assembleArgs(fragments)
    }

    /// First half of argv expansion: walk the word and resolve every
    /// substitution. The result is a list of ``WordFragment``s carrying
    /// quote/source provenance so the *caller* can decide when to do
    /// field splitting (which depends on `$IFS`, possibly modified by
    /// a prefix assignment that hasn't been applied yet).
    func collectArgFragments(word node: Node) async throws -> [WordFragment] {
        let parts: [Node]
        switch node.kind {
        case .word(_, let p), .assignment(_, let p):
            parts = p
        default:
            return []
        }

        let chars = Array(currentSource)
        let lo = max(0, node.range.lowerBound)
        let hi = min(chars.count, node.range.upperBound)
        guard lo < hi else { return [] }

        return try await collectFragments(
            chars: chars, lo: lo, hi: hi, parts: parts)
    }

    /// Second half of argv expansion: take fragments from
    /// ``collectArgFragments(word:)`` and apply field splitting using
    /// the *current* `$IFS`. Renamed from the old internal helper so
    /// the executor can call it after applying prefix assignments.
    func assembleArgs(_ fragments: [WordFragment]) -> [String] {
        return assembleFragmentsToArgs(fragments)
    }

    // MARK: Fragment collection

    /// One piece of a word, tagged with how it came in. The caller's
    /// assembler decides whether to merge it into the current arg or
    /// split it out into separate args.
    enum WordFragment {
        /// Came from quoted text (single or double), an escaped char,
        /// or unquoted literal source. No further splitting.
        case literal(String)
        /// Came from an *unquoted* substitution — `$VAR`, `$(cmd)`,
        /// `$((expr))`, or unquoted `$*`. Subject to `$IFS` splitting.
        case unquotedSub(String)
        /// `"$@"` — each value is its own piece, no further splitting.
        case dollarAtQuoted([String])
        /// `$@` (unquoted) — each value, then individually `$IFS`-split.
        case dollarAtUnquoted([String])
    }

    private func collectFragments(chars: [Character],
                                  lo: Int, hi: Int,
                                  parts: [Node]) async throws -> [WordFragment]
    {
        var fragments: [WordFragment] = []
        var literalBuf = ""
        var inDoubleQuote = false
        // Snapshot when entering a quote — used to decide whether the
        // pair was empty (so `""` and `''` emit an explicit empty
        // literal even though no characters or substitutions appeared).
        var quoteEnterFragments = 0
        var quoteEnterBufLen = 0

        func flushLiteral() {
            if !literalBuf.isEmpty {
                fragments.append(.literal(literalBuf))
                literalBuf = ""
            }
        }

        var queue = parts.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var i = lo

        while i < hi {
            // Substitution at this position?
            if let head = queue.first, i == head.range.lowerBound {
                if case .parameter(let body) = head.kind {
                    if body == "@" {
                        flushLiteral()
                        if inDoubleQuote {
                            fragments.append(
                                .dollarAtQuoted(positionalParameters))
                        } else {
                            fragments.append(
                                .dollarAtUnquoted(positionalParameters))
                        }
                        i = min(hi, head.range.upperBound)
                        queue.removeFirst()
                        continue
                    }
                    if body == "*" {
                        flushLiteral()
                        // `"$*"` joins on the first IFS char (default
                        // space). Unquoted `$*` uses the same join then
                        // gets IFS-split downstream — usually equivalent
                        // to unquoted `$@` for simple params.
                        let joined = positionalParameters
                            .joined(separator: dollarStarSeparator())
                        if inDoubleQuote {
                            literalBuf += joined
                        } else {
                            fragments.append(.unquotedSub(joined))
                        }
                        i = min(hi, head.range.upperBound)
                        queue.removeFirst()
                        continue
                    }
                    // `arr[@]` and `arr[*]` — give the same per-arg
                    // splitting behaviour as `$@` / `$*`.
                    if let (arrName, sub) = arraySubscript(of: body) {
                        let values =
                            environment.arrays[arrName]?.elementsInOrder ?? []
                        if sub == "@" {
                            flushLiteral()
                            if inDoubleQuote {
                                fragments.append(.dollarAtQuoted(values))
                            } else {
                                fragments.append(.dollarAtUnquoted(values))
                            }
                            i = min(hi, head.range.upperBound)
                            queue.removeFirst()
                            continue
                        }
                        if sub == "*" {
                            flushLiteral()
                            let joined = values
                                .joined(separator: dollarStarSeparator())
                            if inDoubleQuote {
                                literalBuf += joined
                            } else {
                                fragments.append(.unquotedSub(joined))
                            }
                            i = min(hi, head.range.upperBound)
                            queue.removeFirst()
                            continue
                        }
                        // `arr[N]` — falls through to generic resolve.
                    }
                }
                let value = try await resolve(part: head)
                if inDoubleQuote {
                    literalBuf += value
                } else {
                    flushLiteral()
                    fragments.append(.unquotedSub(value))
                }
                i = min(hi, head.range.upperBound)
                queue.removeFirst()
                continue
            }

            let c = chars[i]
            if c == "'" {
                // Single-quoted: every char between the quotes is
                // literal, including `$`. An empty `''` still emits an
                // empty literal so `cmd ''` becomes `cmd ""`.
                let beforeFragments = fragments.count
                let beforeLitLen = literalBuf.count
                i += 1
                while i < hi, chars[i] != "'" {
                    literalBuf.append(chars[i])
                    i += 1
                }
                if i < hi { i += 1 }
                if fragments.count == beforeFragments,
                   literalBuf.count == beforeLitLen
                {
                    fragments.append(.literal(""))
                }
                continue
            }
            if c == "\"" {
                if inDoubleQuote {
                    // Closing — check if the pair was empty.
                    if fragments.count == quoteEnterFragments,
                       literalBuf.count == quoteEnterBufLen
                    {
                        fragments.append(.literal(""))
                    }
                    inDoubleQuote = false
                } else {
                    quoteEnterFragments = fragments.count
                    quoteEnterBufLen = literalBuf.count
                    inDoubleQuote = true
                }
                i += 1
                continue
            }
            if c == "\\" {
                i += 1
                if i < hi {
                    literalBuf.append(chars[i])
                    i += 1
                }
                continue
            }
            literalBuf.append(c)
            i += 1
        }
        flushLiteral()
        return fragments
    }

    // MARK: Assembly

    private func assembleFragmentsToArgs(_ fragments: [WordFragment]) -> [String] {
        var args: [String] = []
        var current = ""
        // True once any fragment has contributed to `current` — even if
        // that contribution was the empty string (from `""` or `''`).
        // Distinguishes `cmd ""` (1 arg, "") from `cmd $UNSET` (0 args).
        var currentLive = false

        func startNewArg() {
            args.append(current)
            current = ""
            currentLive = false
        }

        for frag in fragments {
            switch frag {
            case .literal(let s):
                current += s
                currentLive = true

            case .unquotedSub(let s):
                let pieces = ifsSplit(s)
                if pieces.isEmpty { continue }
                appendPiecesAsArgs(pieces,
                                   current: &current,
                                   currentLive: &currentLive,
                                   args: &args)

            case .dollarAtQuoted(let values):
                if values.isEmpty { continue }
                appendPiecesAsArgs(values,
                                   current: &current,
                                   currentLive: &currentLive,
                                   args: &args)

            case .dollarAtUnquoted(let values):
                if values.isEmpty { continue }
                var pieces: [String] = []
                for value in values {
                    pieces.append(contentsOf: ifsSplit(value))
                }
                if pieces.isEmpty { continue }
                appendPiecesAsArgs(pieces,
                                   current: &current,
                                   currentLive: &currentLive,
                                   args: &args)
            }
        }

        if currentLive { args.append(current) }
        return args
    }

    private func appendPiecesAsArgs(
        _ pieces: [String],
        current: inout String,
        currentLive: inout Bool,
        args: inout [String]
    ) {
        for (idx, piece) in pieces.enumerated() {
            if idx == 0 {
                current += piece
            } else {
                args.append(current)
                current = piece
            }
            currentLive = true
        }
    }

    /// Split `s` on the active `$IFS` value, following bash's two-tier
    /// rule:
    ///
    /// - **Whitespace IFS chars** (`space`, `tab`, `newline` — by
    ///   default *all* of `$IFS`): runs of them collapse to a single
    ///   delimiter; leading/trailing runs produce no empty fields.
    /// - **Non-whitespace IFS chars** (e.g. `:` when `IFS=":"`): each
    ///   one is a *hard* delimiter that *does* produce an empty field
    ///   if there's nothing to its left, and it absorbs adjacent
    ///   whitespace IFS chars.
    ///
    /// Special cases:
    /// - `IFS` unset → default `" \t\n"`.
    /// - `IFS` set to empty string → no splitting (returns `[s]`).
    /// - Empty input → `[]`.
    func ifsSplit(_ s: String) -> [String] {
        guard let ifs = environment["IFS"] else {
            return defaultWhitespaceSplit(s)
        }
        if ifs.isEmpty { return [s] }
        if s.isEmpty { return [] }

        let defaultWhitespace: Set<Character> = [" ", "\t", "\n"]
        let ifsChars = Set(ifs)
        let ifsWhitespace = ifsChars.intersection(defaultWhitespace)
        let ifsHard = ifsChars.subtracting(defaultWhitespace)

        // Pure-whitespace IFS: just collapse runs and trim edges.
        if ifsHard.isEmpty {
            return s.split(whereSeparator: { ifsWhitespace.contains($0) })
                    .map(String.init)
        }

        // Each delimiter *run* (a maximal block of IFS chars) ends one
        // field and contributes some number of empty fields:
        // - hardCount = 0 (run is pure whitespace) → emit the field
        //   only if non-empty; no empties.
        // - hardCount > 0 → emit the field unconditionally, then
        //   `hardCount - 1` extra empty fields.
        //
        // This is what makes "a : b" yield ["a", "b"] (one delimiter
        // total — surrounding whitespace is absorbed by the colon)
        // while "a::b" yields ["a", "", "b"] (two delimiters → empty
        // between them) and "a:" yields just ["a"] (trailing single
        // hard doesn't add an empty after the last field).
        var fields: [String] = []
        var current = ""
        var i = s.startIndex

        while i < s.endIndex {
            let c = s[i]
            if !ifsChars.contains(c) {
                current.append(c)
                i = s.index(after: i)
                continue
            }
            // Start of a delimiter run.
            var hardCount = 0
            while i < s.endIndex, ifsChars.contains(s[i]) {
                if ifsHard.contains(s[i]) { hardCount += 1 }
                i = s.index(after: i)
            }
            if hardCount == 0 {
                if !current.isEmpty {
                    fields.append(current)
                    current = ""
                }
            } else {
                fields.append(current)
                current = ""
                for _ in 1..<hardCount {
                    fields.append("")
                }
            }
        }
        if !current.isEmpty {
            fields.append(current)
        }
        return fields
    }

    private func defaultWhitespaceSplit(_ s: String) -> [String] {
        let ws: Set<Character> = [" ", "\t", "\n"]
        return s.split(whereSeparator: { ws.contains($0) }).map(String.init)
    }

    /// First char of `$IFS` (unset ⇒ `" "`, empty ⇒ `""`). Used to
    /// join `$*` / `"$*"`.
    private func dollarStarSeparator() -> String {
        guard let ifs = environment["IFS"] else { return " " }
        if ifs.isEmpty { return "" }
        return String(ifs.first!)
    }

    /// Split `arr[sub]` into `("arr", "sub")`. Only matches when the
    /// part before `[` is a valid identifier — so `${#arr[@]}` (which
    /// has body `#arr[@]`) doesn't get misclassified here and stays
    /// on the slow path through ``resolveParameter``.
    private func arraySubscript(of body: String) -> (String, String)? {
        guard let lb = body.firstIndex(of: "["), body.last == "]" else {
            return nil
        }
        let head = String(body[..<lb])
        guard let first = head.first,
              first.isLetter || first == "_",
              head.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        let after = body.index(after: lb)
        let last = body.index(before: body.endIndex)
        guard after <= last else { return nil }
        let sub = String(body[after..<last])
        return (head, sub)
    }
}
