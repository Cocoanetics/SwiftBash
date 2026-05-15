import Foundation

extension Parser {

    // MARK: - Conditional `[[ … ]]` + arithmetic `(( … ))`

    /// `[[ EXPR ]]` — collect everything between the brackets as a
    /// flat token list. Operators (`&&`, `||`, `<`, `>`, `(`, `)`,
    /// `!`) are reified as small nodes so the interpreter has a
    /// uniform list to walk. We match `]]` by literal value because
    /// the tokenizer's reserved-word recognition only fires at
    /// command-start positions, not after operand words.
    func parseConditional() throws -> Node {
        let start = try expect(.condStart, "'[['")
        var parts: [Node] = []
        while !isCondEnd(peek()), peek().type != .eof {
            let tok = try next()
            parts.append(condNode(for: tok))
        }
        guard isCondEnd(peek()) else {
            throw BashSyntaxError.parsing(
                message: "expected ']]' to close '[['",
                source: source,
                position: peek().range.lowerBound)
        }
        let end = try next()
        return Node(kind: .conditional(parts: parts),
                    range: start.range.lowerBound..<end.range.upperBound)
    }

    func isCondEnd(_ token: Token) -> Bool {
        token.type == .condEnd || token.value == "]]"
    }

    // Token-to-node mapping table for `[[ … ]]` tokens; each case is a
    // one-line Node constructor — splitting into helpers would scatter
    // the dispatch.
    // swiftlint:disable:next cyclomatic_complexity
    func condNode(for tok: Token) -> Node {
        switch tok.type {
        case .word, .number, .assignmentWord, .redirectWord:
            // Try to expand as a word so $VAR / $(...) etc. become
            // proper sub-nodes — same as in command position.
            if let expanded = try? expandWord(tok, asAssignment: false) {
                return expanded
            }
            return Node(kind: .word(tok.value, parts: []), range: tok.range)
        case .less:
            return Node(kind: .operator("<"), range: tok.range)
        case .greater:
            return Node(kind: .operator(">"), range: tok.range)
        case .andAnd:
            return Node(kind: .operator("&&"), range: tok.range)
        case .orOr:
            return Node(kind: .operator("||"), range: tok.range)
        case .bang:
            return Node(kind: .reservedWord("!"), range: tok.range)
        case .leftParen:
            return Node(kind: .reservedWord("("), range: tok.range)
        case .rightParen:
            return Node(kind: .reservedWord(")"), range: tok.range)
        case .newline, .semicolon:
            // Whitespace-equivalents inside [[ ]] — bash treats them
            // as separators we should drop. Use an operator marker so
            // the AST stays printable; interpreter skips them.
            return Node(kind: .operator(";"), range: tok.range)
        default:
            return Node(kind: .word(tok.value, parts: []), range: tok.range)
        }
    }

    func parseArithmeticCommand() throws -> Node {
        let tok = try next() // arithCommand token, value = expression body
        let arithNode = Node(
            kind: .arithmeticCommand(tok.value),
            range: tok.range)

        var redirects: [Node] = []
        while isRedirectStart(peek()) {
            redirects.append(try parseRedirection())
        }
        let endUpper = redirects.last?.range.upperBound ?? arithNode.range.upperBound
        let span = arithNode.range.lowerBound..<endUpper
        return Node(
            kind: .compound(list: [arithNode], redirects: redirects),
            range: span)
    }
}
