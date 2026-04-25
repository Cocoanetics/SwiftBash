import Foundation

/// A recursive-descent parser over the token stream produced by ``Tokenizer``.
///
/// ``Parser`` is instantiated internally by the public API (``BashSyntax.parse``,
/// ``BashSyntax.parseSingle``) — you usually don't need to touch it directly.
public final class Parser {

    public let source: String
    private let tokenizer: Tokenizer
    private let expansionLimit: Int
    private let proceedOnError: Bool

    /// Buffered tokens (for multi-token lookahead).
    private var buffer: [Token] = []
    /// A tokenizer error that occurred during lookahead, surfaced on the next `consume`.
    private var pendingTokenizerError: Error?

    /// Track the depth of substitution parsing so we can cap runaway recursion.
    private let depth: Int

    public convenience init(_ source: String,
                            expansionLimit: Int = 200,
                            proceedOnError: Bool = false) {
        self.init(source: source, tokenizer: Tokenizer(source),
                  expansionLimit: expansionLimit,
                  proceedOnError: proceedOnError, depth: 0)
    }

    private init(source: String, tokenizer: Tokenizer,
                 expansionLimit: Int, proceedOnError: Bool, depth: Int) {
        self.source = source
        self.tokenizer = tokenizer
        self.expansionLimit = expansionLimit
        self.proceedOnError = proceedOnError
        self.depth = depth
    }

    // MARK: - Public entry points

    /// Parse the full source. May return multiple top-level parts for
    /// multi-line input.
    public func parseAll() throws -> [Node] {
        var parts: [Node] = []
        while true {
            while peek().type == .newline { _ = try next() }
            try surfaceTokenizerError()
            if peek().type == .eof { break }
            let node = try parseSimpleList()
            parts.append(node)
            // After a simple_list, optionally consume terminators.
            while peek().type == .newline { _ = try next() }
        }
        try surfaceTokenizerError()
        return parts.map { attachHeredocBodies($0) }
    }

    /// Parse only the first top-level unit.
    public func parseFirst() throws -> Node {
        while peek().type == .newline { _ = try next() }
        try surfaceTokenizerError()
        if peek().type == .eof {
            throw BashSyntaxError.parsing(message: "unexpected EOF",
                                       source: source,
                                       position: source.count)
        }
        let node = try parseSimpleList()
        try surfaceTokenizerError()
        return attachHeredocBodies(node)
    }

    private func surfaceTokenizerError() throws {
        if let err = pendingTokenizerError {
            pendingTokenizerError = nil
            throw err
        }
    }

    /// Walk `node` and attach heredoc bodies gathered by the tokenizer to
    /// any `<<` / `<<-` redirect nodes whose start position matches.
    private func attachHeredocBodies(_ node: Node) -> Node {
        let bodies = tokenizer.heredocBodies
        if bodies.isEmpty { return node }

        func rewrite(_ n: Node) -> Node {
            switch n.kind {
            case .redirect(let input, let type, let output, let heredoc)
                where (type == "<<" || type == "<<-") && heredoc == nil:
                if let body = bodies[n.range.lowerBound] {
                    let heredocNode = Node(kind: .heredoc(body.body),
                                           range: body.range)
                    let newRange = n.range.lowerBound..<max(n.range.upperBound,
                                                            body.range.upperBound)
                    return Node(
                        kind: .redirect(input: input, type: type,
                                        output: rewrite(output),
                                        heredoc: heredocNode),
                        range: newRange)
                }
                return n
            case .list(let parts):
                return Node(kind: .list(parts: parts.map(rewrite)), range: n.range)
            case .command(let parts):
                return Node(kind: .command(parts: parts.map(rewrite)), range: n.range)
            case .pipeline(let parts):
                return Node(kind: .pipeline(parts: parts.map(rewrite)), range: n.range)
            case .compound(let list, let redirects):
                return Node(
                    kind: .compound(list: list.map(rewrite),
                                    redirects: redirects.map(rewrite)),
                    range: n.range)
            case .word(let w, let parts):
                return Node(kind: .word(w, parts: parts.map(rewrite)), range: n.range)
            case .assignment(let w, let parts):
                return Node(kind: .assignment(w, parts: parts.map(rewrite)),
                            range: n.range)
            case .redirect(let input, let type, let output, let heredoc):
                return Node(
                    kind: .redirect(input: input, type: type,
                                    output: rewrite(output),
                                    heredoc: heredoc.map(rewrite)),
                    range: n.range)
            case .commandSubstitution(let c):
                return Node(kind: .commandSubstitution(command: rewrite(c)),
                            range: n.range)
            case .processSubstitution(let c):
                return Node(kind: .processSubstitution(command: rewrite(c)),
                            range: n.range)
            case .ifCommand(let p):    return Node(kind: .ifCommand(parts: p.map(rewrite)),    range: n.range)
            case .whileCommand(let p): return Node(kind: .whileCommand(parts: p.map(rewrite)), range: n.range)
            case .untilCommand(let p): return Node(kind: .untilCommand(parts: p.map(rewrite)), range: n.range)
            case .forCommand(let p):   return Node(kind: .forCommand(parts: p.map(rewrite)),   range: n.range)
            case .cStyleForCommand(let i, let c, let u, let body):
                return Node(
                    kind: .cStyleForCommand(initExpr: i, condExpr: c,
                                            updateExpr: u, body: rewrite(body)),
                    range: n.range)
            case .caseCommand(let p):  return Node(kind: .caseCommand(parts: p.map(rewrite)),  range: n.range)
            case .pattern(let p):      return Node(kind: .pattern(parts: p.map(rewrite)),      range: n.range)
            case .function(let name, let body, let parts):
                return Node(
                    kind: .function(name: rewrite(name), body: rewrite(body),
                                    parts: parts.map(rewrite)),
                    range: n.range)
            case .unimplemented(let p):
                return Node(kind: .unimplemented(parts: p.map(rewrite)), range: n.range)
            default:
                return n
            }
        }
        return rewrite(node)
    }

    // MARK: - Token plumbing

    private func peek(offset: Int = 0) -> Token {
        while buffer.count <= offset {
            do {
                buffer.append(try tokenizer.nextToken())
            } catch {
                // Record and return EOF so callers can decide; throwing here
                // would force every peek to be `try`. try next() surfaces the error
                // on the next non-buffered read.
                pendingTokenizerError = error
                buffer.append(Token(type: .eof, value: "",
                                    range: source.count..<source.count))
            }
        }
        return buffer[offset]
    }

    @discardableResult
    private func next() throws -> Token {
        if buffer.isEmpty {
            return try tokenizer.nextToken()
        }
        let t = buffer.removeFirst()
        if buffer.isEmpty, let err = pendingTokenizerError {
            // The buffer we just drained was synthesized after a tokenizer
            // error — surface that error now.
            pendingTokenizerError = nil
            if t.type == .eof { throw err }
        }
        return t
    }

    private func expect(_ type: TokenType, _ description: String) throws -> Token {
        let t = peek()
        guard t.type == type else {
            throw BashSyntaxError.parsing(
                message: "expected \(description), found \(t.value.isEmpty ? "EOF" : t.value)",
                source: source,
                position: t.range.lowerBound)
        }
        return try next()
    }

    // MARK: - Grammar

    /// Parse a `simple_list`: one or more pipeline_commands joined by &&, ||, ;, &, \n,
    /// optionally ended by & or ;.
    private func parseSimpleList() throws -> Node {
        var parts: [Node] = []
        parts.append(try parsePipelineCommand())

        while true {
            let t = peek()
            switch t.type {
            case .andAnd, .orOr:
                _ = try next()
                parts.append(Node(kind: .operator(t.value), range: t.range))
                try skipNewlines()
                parts.append(try parsePipelineCommand())
            case .semicolon, .ampersand:
                // could be terminator or separator — peek ahead after consuming
                let sep = try next()
                // If another command follows, it's a separator.
                try skipNewlines()
                if canStartCommand(peek()) {
                    parts.append(Node(kind: .operator(sep.value), range: sep.range))
                    parts.append(try parsePipelineCommand())
                } else {
                    // Terminator form: append operator (especially for `&`).
                    parts.append(Node(kind: .operator(sep.value), range: sep.range))
                    return makeListOrSingle(parts)
                }
            case .newline:
                // `\n` ends simple_list at top level
                return makeListOrSingle(parts)
            default:
                return makeListOrSingle(parts)
            }
        }
    }

    private func canStartCommand(_ t: Token) -> Bool {
        switch t.type {
        case .word, .assignmentWord, .redirectWord, .number,
             .leftParen, .leftCurly,
             .ifKw, .whileKw, .untilKw, .forKw, .caseKw,
             .functionKw, .bang, .less, .greater, .lessLess, .lessLessMinus,
             .lessLessLess, .lessAnd, .greaterAnd, .lessGreater, .greaterBar,
             .greaterGreater, .andGreater, .andGreaterGreater,
             .arithCommand:
            return true
        default:
            return false
        }
    }

    private func makeListOrSingle(_ parts: [Node]) -> Node {
        if parts.count == 1 { return parts[0] }
        return Node(kind: .list(parts: parts), range: spanOf(parts))
    }

    private func skipNewlines() throws {
        while peek().type == .newline { _ = try next() }
    }

    /// Parse a compound_list: like simple_list but with different terminators;
    /// it appears inside control structures. `terminators` lists the reserved
    /// word tokens that end the list.
    private func parseCompoundList(until terminators: Set<TokenType>) throws -> Node {
        try skipNewlines()
        var parts: [Node] = []
        parts.append(try parsePipelineCommand())

        while true {
            let t = peek()
            if terminators.contains(t.type) { break }
            switch t.type {
            case .andAnd, .orOr:
                _ = try next()
                parts.append(Node(kind: .operator(t.value), range: t.range))
                try skipNewlines()
                parts.append(try parsePipelineCommand())
            case .semicolon, .ampersand, .newline:
                let sep = try next()
                try skipNewlines()
                let nxt = peek()
                if terminators.contains(nxt.type) || nxt.type == .eof {
                    if sep.type != .newline {
                        parts.append(Node(kind: .operator(sep.value), range: sep.range))
                    }
                    return makeListOrSingle(parts)
                }
                if sep.type != .newline {
                    parts.append(Node(kind: .operator(sep.value), range: sep.range))
                }
                parts.append(try parsePipelineCommand())
            default:
                return makeListOrSingle(parts)
            }
        }
        return makeListOrSingle(parts)
    }

    // MARK: Pipeline + bang

    private func parsePipelineCommand() throws -> Node {
        var bangNode: Node?
        if peek().type == .bang {
            let t = try next()
            bangNode = Node(kind: .reservedWord(t.value), range: t.range)
        }

        let pipe = try parsePipeline()
        if let bangNode {
            var parts: [Node]
            if case .pipeline(let existing) = pipe.kind {
                parts = [bangNode] + existing
            } else {
                parts = [bangNode, pipe]
            }
            return Node(kind: .pipeline(parts: parts), range: spanOf(parts))
        }
        return pipe
    }

    private func parsePipeline() throws -> Node {
        var parts: [Node] = [try parseCommand()]
        while peek().type == .bar || peek().type == .barAnd {
            let pipeTok = try next()
            parts.append(Node(kind: .pipe(pipeTok.value), range: pipeTok.range))
            try skipNewlines()
            parts.append(try parseCommand())
        }
        if parts.count == 1 { return parts[0] }
        return Node(kind: .pipeline(parts: parts), range: spanOf(parts))
    }

    // MARK: Command

    private func parseCommand() throws -> Node {
        let t = peek()
        let node: Node
        let wantsTrailingRedirects: Bool
        switch t.type {
        case .ifKw:
            node = try parseIf(); wantsTrailingRedirects = true
        case .whileKw:
            node = try parseWhileLike(kind: .whileCommand(parts: []))
            wantsTrailingRedirects = true
        case .untilKw:
            node = try parseWhileLike(kind: .untilCommand(parts: []))
            wantsTrailingRedirects = true
        case .forKw:
            node = try parseFor(); wantsTrailingRedirects = true
        case .caseKw:
            node = try parseCase(); wantsTrailingRedirects = true
        case .leftParen:
            node = try parseSubshell(); wantsTrailingRedirects = true
        case .leftCurly:
            node = try parseGroup(); wantsTrailingRedirects = true
        case .functionKw:
            node = try parseFunctionDefKeyword(); wantsTrailingRedirects = false
        case .arithCommand:
            // parseArithmeticCommand already consumes its own trailing redirects.
            return try parseArithmeticCommand()
        case .condStart:
            return try parseConditional()
        default:
            return try parseSimpleOrFunctionDef()
        }

        guard wantsTrailingRedirects else { return node }
        return try attachTrailingRedirects(to: node)
    }

    /// After parsing a compound command (if/while/for/case/group/subshell),
    /// consume any redirects that follow it on the same command line and
    /// fold them into the compound's `redirects` array.
    private func attachTrailingRedirects(to node: Node) throws -> Node {
        var extra: [Node] = []
        while isRedirectStart(peek()) {
            extra.append(try parseRedirection())
        }
        guard !extra.isEmpty,
              case .compound(let list, let existing) = node.kind
        else { return node }
        let all = existing + extra
        let upper = extra.last!.range.upperBound
        return Node(kind: .compound(list: list, redirects: all),
                    range: node.range.lowerBound..<upper)
    }

    /// `[[ EXPR ]]` — collect everything between the brackets as a
    /// flat token list. Operators (`&&`, `||`, `<`, `>`, `(`, `)`,
    /// `!`) are reified as small nodes so the interpreter has a
    /// uniform list to walk. We match `]]` by literal value because
    /// the tokenizer's reserved-word recognition only fires at
    /// command-start positions, not after operand words.
    private func parseConditional() throws -> Node {
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

    private func isCondEnd(_ t: Token) -> Bool {
        t.type == .condEnd || t.value == "]]"
    }

    private func condNode(for tok: Token) -> Node {
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

    private func parseArithmeticCommand() throws -> Node {
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

    // Function def can start with `name ()` — detect by looking ahead 2 tokens.
    private func parseSimpleOrFunctionDef() throws -> Node {
        if peek().type == .word,
           peek(offset: 1).type == .leftParen
        {
            // Could be function def or a subshell mis-parse. Check for `()`
            if peek(offset: 2).type == .rightParen {
                return try parseFunctionDefBareName()
            }
        }
        return try parseSimpleCommand()
    }

    private func parseFunctionDefBareName() throws -> Node {
        let nameTok = try next() // word
        let lp = try next()      // (
        let rp = try next()      // )
        _ = lp; _ = rp

        // newline_list
        try skipNewlines()

        let nameNode = Node(kind: .word(nameTok.value, parts: []),
                            range: nameTok.range)
        let body = try parseCommand()
        var redirs: [Node] = []
        while isRedirectStart(peek()) {
            redirs.append(try parseRedirection())
        }
        var bodyNode = body
        if !redirs.isEmpty, case .compound(let list, let r) = body.kind {
            let newRange = body.range.lowerBound..<redirs.last!.range.upperBound
            bodyNode = Node(kind: .compound(list: list, redirects: r + redirs),
                            range: newRange)
        }
        let parts = [nameNode, bodyNode]
        return Node(kind: .function(name: nameNode, body: bodyNode, parts: parts),
                    range: spanOf(parts))
    }

    private func parseFunctionDefKeyword() throws -> Node {
        _ = try next() // `function`
        let nameTok = try expect(.word, "function name")
        let nameNode = Node(kind: .word(nameTok.value, parts: []),
                            range: nameTok.range)
        if peek().type == .leftParen {
            _ = try next()
            _ = try expect(.rightParen, "')'")
        }
        try skipNewlines()
        let body = try parseCommand()
        var redirs: [Node] = []
        while isRedirectStart(peek()) {
            redirs.append(try parseRedirection())
        }
        var bodyNode = body
        if !redirs.isEmpty, case .compound(let list, let r) = body.kind {
            let newRange = body.range.lowerBound..<redirs.last!.range.upperBound
            bodyNode = Node(kind: .compound(list: list, redirects: r + redirs),
                            range: newRange)
        }
        let parts = [nameNode, bodyNode]
        return Node(kind: .function(name: nameNode, body: bodyNode, parts: parts),
                    range: spanOf(parts))
    }

    // Simple command: words, assignments, redirections.
    private func parseSimpleCommand() throws -> Node {
        var parts: [Node] = []

        while true {
            let t = peek()
            // NUMBER followed by a redirect operator is an input FD.
            if t.type == .number, isRedirectStart(peek(offset: 1)) {
                parts.append(try parseRedirection())
                continue
            }
            switch t.type {
            case .word, .number:
                _ = try next()
                parts.append(try expandWord(t, asAssignment: false))
            case .assignmentWord:
                _ = try next()
                // `name=(item …)` — array assignment. The tokenizer
                // emits the `name=` part as one assignment word; if
                // the next token is `(`, fold the parenthesised
                // items into an `arrayAssignment` node.
                if t.value.hasSuffix("="), peek().type == .leftParen {
                    parts.append(try parseArrayAssignment(
                        nameToken: t))
                    continue
                }
                parts.append(try expandWord(t, asAssignment: true))
            case .redirectWord:
                _ = try next()
                parts.append(try parseRedirection(withLeading: t))
            case .less, .greater, .lessLess, .lessLessMinus, .lessLessLess,
                 .lessAnd, .greaterAnd, .lessGreater, .greaterBar,
                 .greaterGreater, .andGreater, .andGreaterGreater:
                parts.append(try parseRedirection())
            default:
                // Check for NUMBER followed by redirect operator — handled by redirect().
                if t.type == .number, isRedirectStart(peek(offset: 1)) {
                    parts.append(try parseRedirection())
                    continue
                }
                if parts.isEmpty {
                    throw BashSyntaxError.parsing(
                        message: "unexpected token \(t.value.isEmpty ? "EOF" : t.value)",
                        source: source,
                        position: t.range.lowerBound)
                }
                return Node(kind: .command(parts: parts), range: spanOf(parts))
            }
        }
    }

    /// Parse the `(items …)` portion of `name=(items …)` or
    /// `name+=(items …)`. The `nameToken` is the assignment word
    /// like `arr=` or `arr+=`.
    private func parseArrayAssignment(nameToken: Token) throws -> Node {
        let lp = try expect(.leftParen, "'('")
        var items: [Node] = []
        try skipNewlines()
        while peek().type != .rightParen, peek().type != .eof {
            let tok = try next()
            switch tok.type {
            case .word, .number, .assignmentWord:
                items.append(try expandWord(tok, asAssignment: false))
            case .newline:
                try skipNewlines()
            default:
                throw BashSyntaxError.parsing(
                    message: "unexpected token in array literal: \(tok.value)",
                    source: source,
                    position: tok.range.lowerBound)
            }
            try skipNewlines()
        }
        let rp = try expect(.rightParen, "')'")
        // Strip the trailing `=` and (if present) the `+` for the
        // append form `name+=(…)`.
        var raw = nameToken.value
        guard raw.hasSuffix("=") else {
            throw BashSyntaxError.parsing(
                message: "malformed array assignment: \(raw)",
                source: source,
                position: nameToken.range.lowerBound)
        }
        raw.removeLast()
        let append: Bool
        if raw.hasSuffix("+") {
            raw.removeLast()
            append = true
        } else {
            append = false
        }
        return Node(
            kind: .arrayAssignment(name: raw, items: items, append: append),
            range: nameToken.range.lowerBound..<rp.range.upperBound)
    }

    // MARK: Redirections

    private func isRedirectStart(_ t: Token) -> Bool {
        switch t.type {
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

    /// Parse a redirection. If `withLeading` is provided, that token is the
    /// left-hand side (number or `{name}`).
    private func parseRedirection(withLeading: Token? = nil) throws -> Node {
        // optional leading number or redirect-word
        var inputFD: Int?
        var redirWord: String?
        var leadingRange: Range<Int>?

        if let wl = withLeading {
            if wl.type == .number {
                inputFD = Int(wl.value)
                leadingRange = wl.range
            } else if wl.type == .redirectWord {
                redirWord = wl.value
                leadingRange = wl.range
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
            if case .word(let w, _) = targetNode.kind {
                delimiter = w
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

    private func isRedirectOperator(_ t: TokenType) -> Bool {
        switch t {
        case .less, .greater, .lessLess, .lessLessMinus, .lessLessLess,
             .lessAnd, .greaterAnd, .lessGreater, .greaterBar,
             .greaterGreater, .andGreater, .andGreaterGreater:
            return true
        default: return false
        }
    }

    // MARK: Compound commands

    private func parseIf() throws -> Node {
        let ifTok = try next() // if
        var parts: [Node] = [Node(kind: .reservedWord("if"), range: ifTok.range)]
        let cond = try parseCompoundList(until: [.thenKw])
        parts.append(cond)
        let thenTok = try expect(.thenKw, "'then'")
        parts.append(Node(kind: .reservedWord("then"), range: thenTok.range))
        let body = try parseCompoundList(until: [.elifKw, .elseKw, .fiKw])
        parts.append(body)

        while peek().type == .elifKw {
            let t = try next()
            parts.append(Node(kind: .reservedWord("elif"), range: t.range))
            let c = try parseCompoundList(until: [.thenKw])
            parts.append(c)
            let th = try expect(.thenKw, "'then'")
            parts.append(Node(kind: .reservedWord("then"), range: th.range))
            let b = try parseCompoundList(until: [.elifKw, .elseKw, .fiKw])
            parts.append(b)
        }

        if peek().type == .elseKw {
            let e = try next()
            parts.append(Node(kind: .reservedWord("else"), range: e.range))
            let b = try parseCompoundList(until: [.fiKw])
            parts.append(b)
        }
        let fiTok = try expect(.fiKw, "'fi'")
        parts.append(Node(kind: .reservedWord("fi"), range: fiTok.range))

        let ifNode = Node(kind: .ifCommand(parts: parts), range: spanOf(parts))
        return Node(kind: .compound(list: [ifNode], redirects: []),
                    range: ifNode.range)
    }

    private func parseWhileLike(kind: Node.Kind) throws -> Node {
        let kw = try next() // while / until
        let reservedName = kw.value
        var parts: [Node] = [Node(kind: .reservedWord(reservedName), range: kw.range)]
        let cond = try parseCompoundList(until: [.doKw])
        parts.append(cond)
        let doTok = try expect(.doKw, "'do'")
        parts.append(Node(kind: .reservedWord("do"), range: doTok.range))
        let body = try parseCompoundList(until: [.doneKw])
        parts.append(body)
        let doneTok = try expect(.doneKw, "'done'")
        parts.append(Node(kind: .reservedWord("done"), range: doneTok.range))

        let inner: Node
        switch kind {
        case .whileCommand:
            inner = Node(kind: .whileCommand(parts: parts), range: spanOf(parts))
        case .untilCommand:
            inner = Node(kind: .untilCommand(parts: parts), range: spanOf(parts))
        default:
            inner = Node(kind: .ifCommand(parts: parts), range: spanOf(parts))
        }
        return Node(kind: .compound(list: [inner], redirects: []), range: inner.range)
    }

    private func parseFor() throws -> Node {
        let forTok = try next()

        // C-style: `for ((init; cond; update)); do … done`. The
        // tokenizer emits the whole `((…))` as one `.arithCommand`
        // token whose value is `init; cond; update`.
        try skipNewlines()
        if peek().type == .arithCommand {
            return try parseCStyleFor(startingAt: forTok)
        }

        var parts: [Node] = [Node(kind: .reservedWord("for"), range: forTok.range)]
        let nameTok = try expect(.word, "variable name")
        parts.append(Node(kind: .word(nameTok.value, parts: []), range: nameTok.range))

        // optional `in WORDS` or `; [newline]`
        try skipNewlines()
        if peek().type == .inKw {
            let inTok = try next()
            parts.append(Node(kind: .reservedWord("in"), range: inTok.range))
            // After `for X in`, words shaped like `k=v` look like
            // assignments to the tokenizer but here they're plain
            // words — accept `.assignmentWord` too.
            while peek().type == .word || peek().type == .number
                  || peek().type == .assignmentWord
            {
                let wt = try next()
                parts.append(try expandWord(wt, asAssignment: false))
            }
            // optional ; or \n
            if peek().type == .semicolon {
                let s = try next()
                parts.append(Node(kind: .reservedWord(";"), range: s.range))
            }
            try skipNewlines()
        } else if peek().type == .semicolon {
            let s = try next()
            parts.append(Node(kind: .reservedWord(";"), range: s.range))
            try skipNewlines()
        }

        let doTok = try expect(.doKw, "'do'")
        parts.append(Node(kind: .reservedWord("do"), range: doTok.range))
        let body = try parseCompoundList(until: [.doneKw])
        parts.append(body)
        let doneTok = try expect(.doneKw, "'done'")
        parts.append(Node(kind: .reservedWord("done"), range: doneTok.range))
        let forNode = Node(kind: .forCommand(parts: parts), range: spanOf(parts))
        return Node(kind: .compound(list: [forNode], redirects: []),
                    range: forNode.range)
    }

    /// Parse a C-style `for ((init; cond; update)); do … done`. `forTok`
    /// is the already-consumed `for` keyword; the next token is the
    /// `((…))` arithmetic-command token.
    private func parseCStyleFor(startingAt forTok: Token) throws -> Node {
        let arithTok = try next() // .arithCommand, value = body between `((` and `))`
        let (initExpr, condExpr, updateExpr) =
            try splitCStyleForBody(arithTok.value)

        // Optional `;` and newlines, then `do … done`.
        if peek().type == .semicolon { _ = try next() }
        try skipNewlines()
        _ = try expect(.doKw, "'do'")
        let body = try parseCompoundList(until: [.doneKw])
        let doneTok = try expect(.doneKw, "'done'")
        let span = forTok.range.lowerBound..<doneTok.range.upperBound
        let forNode = Node(
            kind: .cStyleForCommand(initExpr: initExpr,
                                    condExpr: condExpr,
                                    updateExpr: updateExpr,
                                    body: body),
            range: span)
        return Node(kind: .compound(list: [forNode], redirects: []),
                    range: span)
    }

    /// Split the body of a `((init; cond; update))` on top-level `;`,
    /// honouring parens, braces, brackets, and quotes. Bash requires
    /// exactly two `;` separators; missing parts are treated as empty.
    private func splitCStyleForBody(_ body: String) throws
        -> (String, String, String)
    {
        var parts: [String] = [""]
        var depth = 0
        var quote: Character? = nil
        for c in body {
            if let q = quote {
                parts[parts.count - 1].append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                quote = c
                parts[parts.count - 1].append(c)
                continue
            }
            if c == "(" || c == "[" || c == "{" {
                depth += 1
                parts[parts.count - 1].append(c)
                continue
            }
            if c == ")" || c == "]" || c == "}" {
                depth -= 1
                parts[parts.count - 1].append(c)
                continue
            }
            if c == ";", depth == 0 {
                parts.append("")
                continue
            }
            parts[parts.count - 1].append(c)
        }
        // Tolerate 1, 2 or 3 segments — pad with empty strings as bash
        // does for the omitted-parts forms (`for ((;;))`).
        while parts.count < 3 { parts.append("") }
        if parts.count > 3 {
            throw BashSyntaxError.parsing(
                message: "too many `;` in C-style for header",
                source: "", position: 0)
        }
        let trim: (String) -> String = {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return (trim(parts[0]), trim(parts[1]), trim(parts[2]))
    }

    private func parseCase() throws -> Node {
        let caseTok = try next()
        var parts: [Node] = [Node(kind: .reservedWord("case"), range: caseTok.range)]
        let subj = try expect(.word, "case subject")
        parts.append(try expandWord(subj, asAssignment: false))
        try skipNewlines()
        let inTok = try expect(.inKw, "'in'")
        parts.append(Node(kind: .reservedWord("in"), range: inTok.range))
        try skipNewlines()

        while peek().type != .esacKw {
            // pattern list: [(] pat [| pat]* )
            var patParts: [Node] = []
            if peek().type == .leftParen {
                let lp = try next()
                patParts.append(Node(kind: .reservedWord("("), range: lp.range))
            }
            // patterns
            var patterns: [Node] = []
            patterns.append(try expandWord(try expect(.word, "pattern"),
                                           asAssignment: false))
            while peek().type == .bar {
                let b = try next()
                patterns.append(Node(kind: .reservedWord("|"), range: b.range))
                patterns.append(try expandWord(try expect(.word, "pattern"),
                                               asAssignment: false))
            }
            let patNode = Node(kind: .pattern(parts: patterns), range: spanOf(patterns))
            patParts.append(patNode)
            let rp = try expect(.rightParen, "')'")
            patParts.append(Node(kind: .reservedWord(")"), range: rp.range))
            // Optional body list
            try skipNewlines()
            if peek().type != .semiSemi && peek().type != .semiAnd
                && peek().type != .semiSemiAnd && peek().type != .esacKw
            {
                let body = try parseCompoundList(until: [.semiSemi, .semiAnd, .semiSemiAnd, .esacKw])
                patParts.append(body)
            }
            let caseClause = Node(kind: .compound(list: patParts, redirects: []),
                                  range: spanOf(patParts))
            parts.append(caseClause)

            if peek().type == .semiSemi || peek().type == .semiAnd
                || peek().type == .semiSemiAnd
            {
                let sep = try next()
                parts.append(Node(kind: .reservedWord(sep.value), range: sep.range))
                try skipNewlines()
            } else {
                break
            }
        }
        let esacTok = try expect(.esacKw, "'esac'")
        parts.append(Node(kind: .reservedWord("esac"), range: esacTok.range))

        let caseNode = Node(kind: .caseCommand(parts: parts), range: spanOf(parts))
        return Node(kind: .compound(list: [caseNode], redirects: []), range: caseNode.range)
    }

    private func parseSubshell() throws -> Node {
        let lp = try next() // (
        let body = try parseCompoundList(until: [.rightParen])
        let rp = try expect(.rightParen, "')'")
        let parts = [
            Node(kind: .reservedWord("("), range: lp.range),
            body,
            Node(kind: .reservedWord(")"), range: rp.range),
        ]
        return Node(kind: .compound(list: parts, redirects: []),
                    range: spanOf(parts))
    }

    private func parseGroup() throws -> Node {
        let lc = try next() // {
        let body = try parseCompoundList(until: [.rightCurly])
        let rc = try expect(.rightCurly, "'}'")
        let parts = [
            Node(kind: .reservedWord("{"), range: lc.range),
            body,
            Node(kind: .reservedWord("}"), range: rc.range),
        ]
        return Node(kind: .compound(list: parts, redirects: []),
                    range: spanOf(parts))
    }

    // MARK: Word expansion

    private func expandWord(_ token: Token, asAssignment: Bool) throws -> Node {
        let expander = WordExpander { [weak self] body, baseOffset in
            guard let self else {
                return Node(kind: .command(parts: []),
                            range: baseOffset..<baseOffset)
            }
            return try self.parseSub(body: body, baseOffset: baseOffset)
        }

        let result = try expander.expand(token: token)
        let kind: Node.Kind = asAssignment
            ? .assignment(result.expanded, parts: result.parts)
            : .word(result.expanded, parts: result.parts)
        return Node(kind: kind, range: token.range)
    }

    /// Parse a substring as a bash command, adjusting positions to absolute.
    func parseSub(body: String, baseOffset: Int) throws -> Node {
        guard depth < expansionLimit else {
            return Node(kind: .command(parts: []),
                        range: baseOffset..<(baseOffset + body.count))
        }
        let sub = Parser(source: body, tokenizer: Tokenizer(body),
                         expansionLimit: expansionLimit,
                         proceedOnError: proceedOnError, depth: depth + 1)
        let node = try sub.parseFirst()
        return node.shifted(by: baseOffset)
    }

    // MARK: Utility

    private func spanOf(_ parts: [Node]) -> Range<Int> {
        guard let first = parts.first, let last = parts.last else { return 0..<0 }
        return first.range.lowerBound..<last.range.upperBound
    }
}
