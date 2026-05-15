import Foundation

extension Parser {

    // MARK: - Command dispatch

    // Dispatches on the first token to pick the right compound/simple
    // command parser. Each `case` is a one-line call; the
    // wantsTrailingRedirects flag is a simple post-condition.
    // swiftlint:disable:next cyclomatic_complexity
    func parseCommand() throws -> Node {
        let token = peek()
        let node: Node
        let wantsTrailingRedirects: Bool
        switch token.type {
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
    func attachTrailingRedirects(to node: Node) throws -> Node {
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

    // MARK: - Simple command + function defs

    // Function def can start with `name ()` — detect by looking ahead 2 tokens.
    func parseSimpleOrFunctionDef() throws -> Node {
        if peek().type == .word,
           peek(offset: 1).type == .leftParen {
            // Could be function def or a subshell mis-parse. Check for `()`
            if peek(offset: 2).type == .rightParen {
                return try parseFunctionDefBareName()
            }
        }
        return try parseSimpleCommand()
    }

    func parseFunctionDefBareName() throws -> Node {
        let nameTok = try next() // word
        let leftParen = try next()  // (
        let rightParen = try next() // )
        _ = leftParen; _ = rightParen

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
        if !redirs.isEmpty, case .compound(let list, let existing) = body.kind {
            let newRange = body.range.lowerBound..<redirs.last!.range.upperBound
            bodyNode = Node(kind: .compound(list: list, redirects: existing + redirs),
                            range: newRange)
        }
        let parts = [nameNode, bodyNode]
        return Node(kind: .function(name: nameNode, body: bodyNode, parts: parts),
                    range: spanOf(parts))
    }

    func parseFunctionDefKeyword() throws -> Node {
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
        if !redirs.isEmpty, case .compound(let list, let existing) = body.kind {
            let newRange = body.range.lowerBound..<redirs.last!.range.upperBound
            bodyNode = Node(kind: .compound(list: list, redirects: existing + redirs),
                            range: newRange)
        }
        let parts = [nameNode, bodyNode]
        return Node(kind: .function(name: nameNode, body: bodyNode, parts: parts),
                    range: spanOf(parts))
    }

    // Simple command: words, assignments, redirections.
    func parseSimpleCommand() throws -> Node {
        var parts: [Node] = []

        while true {
            let token = peek()
            // NUMBER followed by a redirect operator is an input FD.
            if token.type == .number, isRedirectStart(peek(offset: 1)) {
                parts.append(try parseRedirection())
                continue
            }
            switch token.type {
            case .word, .number:
                _ = try next()
                parts.append(try expandWord(token, asAssignment: false))
            case .assignmentWord:
                _ = try next()
                // `name=(item …)` — array assignment. The tokenizer
                // emits the `name=` part as one assignment word; if
                // the next token is `(`, fold the parenthesised
                // items into an `arrayAssignment` node.
                if token.value.hasSuffix("="), peek().type == .leftParen {
                    parts.append(try parseArrayAssignment(
                        nameToken: token))
                    continue
                }
                parts.append(try expandWord(token, asAssignment: true))
            case .redirectWord:
                _ = try next()
                parts.append(try parseRedirection(withLeading: token))
            case .less, .greater, .lessLess, .lessLessMinus, .lessLessLess,
                 .lessAnd, .greaterAnd, .lessGreater, .greaterBar,
                 .greaterGreater, .andGreater, .andGreaterGreater:
                parts.append(try parseRedirection())
            default:
                // Check for NUMBER followed by redirect operator — handled by redirect().
                if token.type == .number, isRedirectStart(peek(offset: 1)) {
                    parts.append(try parseRedirection())
                    continue
                }
                if parts.isEmpty {
                    throw BashSyntaxError.parsing(
                        message: "unexpected token \(token.value.isEmpty ? "EOF" : token.value)",
                        source: source,
                        position: token.range.lowerBound)
                }
                return Node(kind: .command(parts: parts), range: spanOf(parts))
            }
        }
    }

    /// Parse the `(items …)` portion of `name=(items …)` or
    /// `name+=(items …)`. The `nameToken` is the assignment word
    /// like `arr=` or `arr+=`.
    func parseArrayAssignment(nameToken: Token) throws -> Node {
        _ = try expect(.leftParen, "'('")
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
        let rightParen = try expect(.rightParen, "')'")
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
            range: nameToken.range.lowerBound..<rightParen.range.upperBound)
    }
}
