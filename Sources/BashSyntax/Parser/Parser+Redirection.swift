import Foundation

extension Parser {

    // MARK: - Redirections

    func isRedirectStart(_ token: Token) -> Bool {
        switch token.type {
        case .less, .greater, .lessLess, .lessLessMinus, .lessLessLess,
             .lessAnd, .greaterAnd, .lessGreater, .greaterBar,
             .greaterGreater, .andGreater, .andGreaterGreater:
            return true
        case .number:
            // number followed by redir op
            return false
        case .redirectWord:
            return true
        default:
            return false
        }
    }

    // Parse a redirection. If `withLeading` is provided, that token is the
    // left-hand side (number or `{name}`).
    //
    // Multi-branch parser over redirection forms; splitting the
    // leading-token / operator / target trichotomy into helpers would
    // scatter shared local state (leadingRange, opTok).
    // swiftlint:disable:next function_body_length
    func parseRedirection(withLeading: Token? = nil) throws -> Node {
        // optional leading number or redirect-word
        var inputFD: Int?
        var redirWord: String?
        var leadingRange: Range<Int>?

        if let leading = withLeading {
            if leading.type == .number {
                inputFD = Int(leading.value)
                leadingRange = leading.range
            } else if leading.type == .redirectWord {
                redirWord = leading.value
                leadingRange = leading.range
            }
        } else if peek().type == .number, isRedirectStart(peek(offset: 1)) {
            let num = try next()
            inputFD = Int(num.value)
            leadingRange = num.range
        }

        let opTok = try next() // the redirect operator
        guard case let opType = opTok.type, isRedirectOperator(opType) else {
            throw BashSyntaxError.parsing(
                message: "expected redirection operator",
                source: source, position: opTok.range.lowerBound)
        }

        let isHeredoc = (opType == .lessLess || opType == .lessLessMinus)

        // Target token: a WORD, NUMBER, or DASH (for <& >& forms).
        let target = peek()
        let targetNode: Node
        switch target.type {
        case .word, .number:
            _ = try next()
            let wordNode = try expandWord(target, asAssignment: false)
            targetNode = wordNode
        case .dash:
            _ = try next()
            targetNode = Node(kind: .word("-", parts: []), range: target.range)
        default:
            throw BashSyntaxError.parsing(
                message: "redirection missing target",
                source: source, position: target.range.lowerBound)
        }

        let start = leadingRange?.lowerBound ?? opTok.range.lowerBound
        let end = targetNode.range.upperBound

        // Build the redirect node WITHOUT heredoc body; parser will attach
        // heredoc content after the next NEWLINE (via the tokenizer).
        if isHeredoc {
            // Register pending heredoc with delimiter (we use the target word's
            // expanded value — without quotes).
            let delimiter: String
            if case .word(let word, _) = targetNode.kind {
                delimiter = word
            } else {
                delimiter = ""
            }
            tokenizer.registerHeredoc(
                delimiter: delimiter,
                stripTabs: opType == .lessLessMinus,
                start: opTok.range.lowerBound)
        }

        let node = Node(
            kind: .redirect(input: inputFD, type: opTok.value,
                            output: targetNode, heredoc: nil),
            range: start..<end)

        _ = redirWord // not currently encoded in the node; stored in value
        return node
    }

    func isRedirectOperator(_ tokenType: TokenType) -> Bool {
        switch tokenType {
        case .less, .greater, .lessLess, .lessLessMinus, .lessLessLess,
             .lessAnd, .greaterAnd, .lessGreater, .greaterBar,
             .greaterGreater, .andGreater, .andGreaterGreater:
            return true
        default: return false
        }
    }
}
