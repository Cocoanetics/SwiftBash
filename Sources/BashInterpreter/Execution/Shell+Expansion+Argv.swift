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
        let assembled = assembleArgs(fragments)
        let braced = braceExpandIfWordHasUnquotedBraces(
            node: node, args: assembled)
        // Pathname expansion: `for f in *.txt` should iterate the
        // matching files, not the literal pattern.
        var out: [String] = []
        for arg in braced {
            out.append(contentsOf: try await globExpand(
                arg, originalWord: node))
        }
        return out
    }

    /// First half of argv expansion: walk the word and resolve every
    /// substitution. The result is a list of ``WordFragment``s carrying
    /// quote/source provenance so the *caller* can decide when to do
    /// field splitting (which depends on `$IFS`, possibly modified by
    /// a prefix assignment that hasn't been applied yet).
    func collectArgFragments(word node: Node) async throws -> [WordFragment] {
        let parts: [Node]
        switch node.kind {
        case .word(_, let nodeParts), .assignment(_, let nodeParts):
            parts = nodeParts
        default:
            return []
        }

        let chars = Array(currentSource)
        let low = max(0, node.range.lowerBound)
        let high = min(chars.count, node.range.upperBound)
        guard low < high else { return [] }

        return try await collectFragments(
            chars: chars, low: low, high: high, parts: parts)
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

    // Top-level expansion driver: routes over substitution nodes plus
    // quote-state characters; per-case helpers would scatter the
    // tightly-coupled lookahead and quote-state across multiple
    // functions.
    // swiftlint:disable:next function_body_length
    private func collectFragments(chars: [Character],
                                  low: Int, high: Int,
                                  parts: [Node]) async throws -> [WordFragment] {
        var builder = FragmentBuilder()
        var inDoubleQuote = false
        // Snapshot when entering a quote — used to decide whether the
        // pair was empty (so `""` and `''` emit an explicit empty
        // literal even though no characters or substitutions appeared).
        var quoteEnterFragments = 0
        var quoteEnterBufLen = 0

        var queue = parts.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var index = low

        while index < high {
            // Substitution at this position?
            if let head = queue.first, index == head.range.lowerBound {
                if case .parameter(let body) = head.kind,
                   try await handleSpecialParameter(
                        body: body,
                        inDoubleQuote: inDoubleQuote,
                        builder: &builder) {
                    index = min(high, head.range.upperBound)
                    queue.removeFirst()
                    continue
                }
                let value = try await resolve(part: head)
                if inDoubleQuote {
                    builder.literalBuf += value
                } else {
                    builder.flushLiteral()
                    builder.fragments.append(.unquotedSub(value))
                }
                index = min(high, head.range.upperBound)
                queue.removeFirst()
                continue
            }

            let char = chars[index]
            if char == "'", !inDoubleQuote {
                index = handleSingleQuoteAt(chars: chars, low: low, high: high,
                                            index: index, builder: &builder)
                continue
            }
            if char == "\"" {
                if inDoubleQuote {
                    // Closing — check if the pair was empty.
                    if builder.fragments.count == quoteEnterFragments,
                       builder.literalBuf.count == quoteEnterBufLen {
                        builder.fragments.append(.literal(""))
                    }
                    inDoubleQuote = false
                } else {
                    quoteEnterFragments = builder.fragments.count
                    quoteEnterBufLen = builder.literalBuf.count
                    inDoubleQuote = true
                }
                index += 1
                continue
            }
            if char == "\\" {
                index = handleBackslashAt(chars: chars, high: high, index: index,
                                          inDoubleQuote: inDoubleQuote,
                                          builder: &builder)
                continue
            }
            builder.literalBuf.append(char)
            index += 1
        }
        builder.flushLiteral()
        return builder.fragments
    }

    /// Handle a `'…'` or `$'…'` quoted region starting at `index`
    /// (the opening single-quote). Mutates the builder in place and
    /// returns the index just past the closing `'`.
    private func handleSingleQuoteAt(chars: [Character],
                                     low: Int, high: Int,
                                     index startIndex: Int,
                                     builder: inout FragmentBuilder) -> Int {
        // ANSI-C quoting: `$'…'`. The leading literal `$`
        // we appended on the prior iteration is the marker
        // that we're inside a `$'`-prefixed quote — strip
        // it and run the body through bash's C-style
        // backslash decoder (so `\033`, `\e`, `\n`, `\x1b`,
        // `é`, etc. expand to the right bytes).
        // Inside the body, only `\'` and `\\` affect the
        // closing-quote scan; every other escape is left
        // for the decoder.
        let isAnsiC = (startIndex > low && chars[startIndex - 1] == "$"
                       && !builder.literalBuf.isEmpty
                       && builder.literalBuf.last == "$")
        let beforeFragments = builder.fragments.count
        let beforeLitLen = builder.literalBuf.count
        var index = startIndex
        if isAnsiC {
            builder.literalBuf.removeLast()    // consume the `$`
            index += 1                         // consume the opening `'`
            var body = ""
            while index < high, chars[index] != "'" {
                if chars[index] == "\\", index + 1 < high {
                    // Preserve the escape pair as-is; the
                    // decoder interprets it (including `\'`,
                    // which musn't terminate the quote here).
                    body.append(chars[index])
                    body.append(chars[index + 1])
                    index += 2
                    continue
                }
                body.append(chars[index])
                index += 1
            }
            builder.literalBuf += Self.decodeAnsiCEscapes(body)
        } else {
            // Plain single-quoted: every char is literal,
            // including `$`. An empty `''` still emits an
            // empty literal so `cmd ''` becomes `cmd ""`.
            // Inside a `"..."` run a `'` is just a literal
            // character.
            index += 1
            while index < high, chars[index] != "'" {
                builder.literalBuf.append(chars[index])
                index += 1
            }
        }
        if index < high { index += 1 }
        if builder.fragments.count == beforeFragments,
           builder.literalBuf.count == beforeLitLen {
            builder.fragments.append(.literal(""))
        }
        return index
    }

    /// Handle a `\X` escape at `index` (the backslash). Mutates the
    /// builder in place and returns the index just past the escape.
    private func handleBackslashAt(chars: [Character],
                                   high: Int,
                                   index startIndex: Int,
                                   inDoubleQuote: Bool,
                                   builder: inout FragmentBuilder) -> Int {
        var index = startIndex + 1
        guard index < high else { return index }
        let next = chars[index]
        // POSIX line continuation: `\<newline>` removes both
        // characters. Applies outside single quotes and even
        // inside double quotes.
        if next == "\n" { return index + 1 }
        if inDoubleQuote, !"$`\"\\".contains(next) {
            // Inside "..." backslash only escapes the meta
            // chars `$ ` " \`; everywhere else `\X` stays
            // as two characters (e.g. `\n` inside a dquoted
            // word fed to `printf`).
            builder.literalBuf.append("\\")
            builder.literalBuf.append(next)
        } else {
            builder.literalBuf.append(next)
        }
        return index + 1
    }
}
