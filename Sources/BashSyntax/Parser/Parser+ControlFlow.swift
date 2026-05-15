import Foundation

extension Parser {

    // MARK: - if / while / until

    func parseIf() throws -> Node {
        let ifTok = try next() // if
        var parts: [Node] = [Node(kind: .reservedWord("if"), range: ifTok.range)]
        let cond = try parseCompoundList(until: [.thenKw])
        parts.append(cond)
        let thenTok = try expect(.thenKw, "'then'")
        parts.append(Node(kind: .reservedWord("then"), range: thenTok.range))
        let body = try parseCompoundList(until: [.elifKw, .elseKw, .fiKw])
        parts.append(body)

        while peek().type == .elifKw {
            let elifTok = try next()
            parts.append(Node(kind: .reservedWord("elif"), range: elifTok.range))
            let elifCond = try parseCompoundList(until: [.thenKw])
            parts.append(elifCond)
            let thenTok2 = try expect(.thenKw, "'then'")
            parts.append(Node(kind: .reservedWord("then"), range: thenTok2.range))
            let elifBody = try parseCompoundList(until: [.elifKw, .elseKw, .fiKw])
            parts.append(elifBody)
        }

        if peek().type == .elseKw {
            let elseTok = try next()
            parts.append(Node(kind: .reservedWord("else"), range: elseTok.range))
            let elseBody = try parseCompoundList(until: [.fiKw])
            parts.append(elseBody)
        }
        let fiTok = try expect(.fiKw, "'fi'")
        parts.append(Node(kind: .reservedWord("fi"), range: fiTok.range))

        let ifNode = Node(kind: .ifCommand(parts: parts), range: spanOf(parts))
        return Node(kind: .compound(list: [ifNode], redirects: []),
                    range: ifNode.range)
    }

    func parseWhileLike(kind: Node.Kind) throws -> Node {
        let keyword = try next() // while / until
        let reservedName = keyword.value
        var parts: [Node] = [Node(kind: .reservedWord(reservedName), range: keyword.range)]
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

    // MARK: - for / C-style for

    func parseFor() throws -> Node {
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
                  || peek().type == .assignmentWord {
                let wordTok = try next()
                parts.append(try expandWord(wordTok, asAssignment: false))
            }
            // optional ; or \n
            if peek().type == .semicolon {
                let sep = try next()
                parts.append(Node(kind: .reservedWord(";"), range: sep.range))
            }
            try skipNewlines()
        } else if peek().type == .semicolon {
            let sep = try next()
            parts.append(Node(kind: .reservedWord(";"), range: sep.range))
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
    func parseCStyleFor(startingAt forTok: Token) throws -> Node {
        let arithTok = try next() // .arithCommand, value = body between `((` and `))`
        let header = try splitCStyleForBody(arithTok.value)
        let initExpr = header.initExpr
        let condExpr = header.condExpr
        let updateExpr = header.updateExpr

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

    struct CStyleForHeader {
        let initExpr: String
        let condExpr: String
        let updateExpr: String
    }

    // Split the body of a `((init; cond; update))` on top-level `;`,
    // honouring parens, braces, brackets, and quotes. Bash requires
    // exactly two `;` separators; missing parts are treated as empty.
    func splitCStyleForBody(_ body: String) throws -> CStyleForHeader {
        var parts: [String] = [""]
        var depth = 0
        var quote: Character?
        for char in body {
            if let activeQuote = quote {
                parts[parts.count - 1].append(char)
                if char == activeQuote { quote = nil }
                continue
            }
            if char == "'" || char == "\"" || char == "`" {
                quote = char
                parts[parts.count - 1].append(char)
                continue
            }
            if char == "(" || char == "[" || char == "{" {
                depth += 1
                parts[parts.count - 1].append(char)
                continue
            }
            if char == ")" || char == "]" || char == "}" {
                depth -= 1
                parts[parts.count - 1].append(char)
                continue
            }
            if char == ";", depth == 0 {
                parts.append("")
                continue
            }
            parts[parts.count - 1].append(char)
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
        return CStyleForHeader(initExpr: trim(parts[0]),
                               condExpr: trim(parts[1]),
                               updateExpr: trim(parts[2]))
    }

    // MARK: - case

    func parseCase() throws -> Node {
        let caseTok = try next()
        var parts: [Node] = [Node(kind: .reservedWord("case"), range: caseTok.range)]
        let subj = try expect(.word, "case subject")
        parts.append(try expandWord(subj, asAssignment: false))
        try skipNewlines()
        let inTok = try expect(.inKw, "'in'")
        parts.append(Node(kind: .reservedWord("in"), range: inTok.range))
        try skipNewlines()

        while peek().type != .esacKw {
            parts.append(try parseCaseClause())
            if peek().type == .semiSemi || peek().type == .semiAnd
                || peek().type == .semiSemiAnd {
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

    /// Parse one `[(] pat [| pat]* ) [body]` clause inside a `case`.
    private func parseCaseClause() throws -> Node {
        var patParts: [Node] = []
        if peek().type == .leftParen {
            let leftParen = try next()
            patParts.append(Node(kind: .reservedWord("("), range: leftParen.range))
        }
        var patterns: [Node] = []
        patterns.append(try expandWord(try expect(.word, "pattern"),
                                       asAssignment: false))
        while peek().type == .bar {
            let barTok = try next()
            patterns.append(Node(kind: .reservedWord("|"), range: barTok.range))
            patterns.append(try expandWord(try expect(.word, "pattern"),
                                           asAssignment: false))
        }
        let patNode = Node(kind: .pattern(parts: patterns), range: spanOf(patterns))
        patParts.append(patNode)
        let rightParen = try expect(.rightParen, "')'")
        patParts.append(Node(kind: .reservedWord(")"), range: rightParen.range))
        // Optional body list
        try skipNewlines()
        if peek().type != .semiSemi && peek().type != .semiAnd
            && peek().type != .semiSemiAnd && peek().type != .esacKw {
            let body = try parseCompoundList(until: [.semiSemi, .semiAnd, .semiSemiAnd, .esacKw])
            patParts.append(body)
        }
        return Node(kind: .compound(list: patParts, redirects: []),
                    range: spanOf(patParts))
    }

    // MARK: - subshell / group

    func parseSubshell() throws -> Node {
        let leftParen = try next() // (
        let body = try parseCompoundList(until: [.rightParen])
        let rightParen = try expect(.rightParen, "')'")
        let parts = [
            Node(kind: .reservedWord("("), range: leftParen.range),
            body,
            Node(kind: .reservedWord(")"), range: rightParen.range)
        ]
        return Node(kind: .compound(list: parts, redirects: []),
                    range: spanOf(parts))
    }

    func parseGroup() throws -> Node {
        let leftCurly = try next() // {
        let body = try parseCompoundList(until: [.rightCurly])
        let rightCurly = try expect(.rightCurly, "'}'")
        let parts = [
            Node(kind: .reservedWord("{"), range: leftCurly.range),
            body,
            Node(kind: .reservedWord("}"), range: rightCurly.range)
        ]
        return Node(kind: .compound(list: parts, redirects: []),
                    range: spanOf(parts))
    }
}
