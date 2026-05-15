import Foundation

extension Shell {

    /// Output buffer collected by ``collectFragments`` — fragments built
    /// so far plus the in-progress literal text. Passed around as a
    /// single inout reference so the per-substitution helpers don't
    /// need a long parameter list.
    struct FragmentBuilder {
        var fragments: [WordFragment] = []
        var literalBuf: String = ""

        mutating func flushLiteral() {
            if !literalBuf.isEmpty {
                fragments.append(.literal(literalBuf))
                literalBuf = ""
            }
        }
    }

    /// Handle `$@`, `$*`, `${!arr[@]}`, `${!arr[*]}`, `arr[@]`,
    /// `arr[*]` — bash's array / positional-list parameters that
    /// produce one-arg-per-element semantics. Returns `true` when the
    /// body matched one of these forms (caller advances past the node);
    /// `false` to fall through to the generic ``resolve(part:)`` path.
    func handleSpecialParameter(
        body: String,
        inDoubleQuote: Bool,
        builder: inout FragmentBuilder
    ) async throws -> Bool {
        if body == "@" {
            builder.flushLiteral()
            if inDoubleQuote {
                builder.fragments.append(.dollarAtQuoted(positionalParameters))
            } else {
                builder.fragments.append(.dollarAtUnquoted(positionalParameters))
            }
            return true
        }
        if body == "*" {
            builder.flushLiteral()
            // `"$*"` joins on the first IFS char (default space).
            // Unquoted `$*` uses the same join then gets IFS-split
            // downstream — usually equivalent to unquoted `$@` for
            // simple params.
            let joined = positionalParameters
                .joined(separator: dollarStarSeparator())
            if inDoubleQuote {
                builder.literalBuf += joined
            } else {
                builder.fragments.append(.unquotedSub(joined))
            }
            return true
        }
        // `${!arr[@]}` / `${!arr[*]}` — list of indices/keys with the
        // same per-arg splitting as `${arr[@]}`. Quoted form preserves
        // spaces in keys; unquoted IFS-splits.
        if body.hasPrefix("!"),
           let (arrName, sub) = arraySubscript(of: String(body.dropFirst())),
           sub == "@" || sub == "*" {
            let keys: [String]
            if let assoc = environment.associativeArrays[arrName] {
                keys = Array(assoc.keys)
            } else if let array = environment.arrays[arrName] {
                keys = array.sortedIndices.map(String.init)
            } else {
                keys = []
            }
            emitArrayElements(keys, marker: sub,
                              inDoubleQuote: inDoubleQuote, builder: &builder)
            return true
        }
        // `arr[@]` / `arr[*]` — same per-arg splitting as `$@` / `$*`.
        if let (arrName, sub) = arraySubscript(of: body), sub == "@" || sub == "*" {
            let values: [String]
            if let assoc = environment.associativeArrays[arrName] {
                values = Array(assoc.values)
            } else {
                values = environment.arrays[arrName]?.elementsInOrder ?? []
            }
            emitArrayElements(values, marker: sub,
                              inDoubleQuote: inDoubleQuote, builder: &builder)
            return true
        }
        return false
    }

    /// Emit a list of array elements with the bash splitting rule for
    /// the given marker: `@` → per-element fragments, `*` → joined.
    private func emitArrayElements(
        _ values: [String],
        marker: String,
        inDoubleQuote: Bool,
        builder: inout FragmentBuilder
    ) {
        if marker == "@" {
            builder.flushLiteral()
            if inDoubleQuote {
                builder.fragments.append(.dollarAtQuoted(values))
            } else {
                builder.fragments.append(.dollarAtUnquoted(values))
            }
        } else {
            // `*` — single space-joined string.
            builder.flushLiteral()
            let joined = values.joined(separator: dollarStarSeparator())
            if inDoubleQuote {
                builder.literalBuf += joined
            } else {
                builder.fragments.append(.unquotedSub(joined))
            }
        }
    }
}
