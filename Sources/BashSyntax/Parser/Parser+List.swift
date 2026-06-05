import Foundation

extension Parser {

    // MARK: - Grammar: lists and pipelines

    /// Parse a `simple_list`: one or more pipeline_commands joined by &&, ||, ;, &, \n,
    /// optionally ended by & or ;.
    func parseSimpleList() throws -> Node {
        var parts: [Node] = []
        parts.append(try parsePipelineCommand())

        while true {
            let token = peek()
            switch token.type {
            case .andAnd, .orOr:
                _ = try next()
                parts.append(Node(kind: .operator(token.value), range: token.range))
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

    func canStartCommand(_ token: Token) -> Bool {
        switch token.type {
        case .word, .assignmentWord, .redirectWord, .number,
             .leftParen, .leftCurly,
             .ifKw, .whileKw, .untilKw, .forKw, .caseKw,
             .functionKw, .bang, .timeKw, .less, .greater, .lessLess, .lessLessMinus,
             .lessLessLess, .lessAnd, .greaterAnd, .lessGreater, .greaterBar,
             .greaterGreater, .andGreater, .andGreaterGreater,
             .arithCommand:
            return true
        default:
            return false
        }
    }

    func makeListOrSingle(_ parts: [Node]) -> Node {
        if parts.count == 1 { return parts[0] }
        return Node(kind: .list(parts: parts), range: spanOf(parts))
    }

    func skipNewlines() throws {
        while peek().type == .newline { _ = try next() }
    }

    /// Parse a compound_list: like simple_list but with different terminators;
    /// it appears inside control structures. `terminators` lists the reserved
    /// word tokens that end the list.
    func parseCompoundList(until terminators: Set<TokenType>) throws -> Node {
        try skipNewlines()
        var parts: [Node] = []
        parts.append(try parsePipelineCommand())

        while true {
            let token = peek()
            if terminators.contains(token.type) { break }
            switch token.type {
            case .andAnd, .orOr:
                _ = try next()
                parts.append(Node(kind: .operator(token.value), range: token.range))
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

    func parsePipelineCommand() throws -> Node {
        // Reserved-word prefixes: `time [-p] [--]` and `!`. bash nests
        // them recursively, so they appear in either order (`time ! …`
        // and `! time …` both parse). Consume at most one of each, in
        // whatever order they arrive. `time`'s `-p` / `--` companions are
        // accepted and dropped (we emit one real/user/sys block anyway).
        var prefix: [Node] = []
        var sawTime = false
        var sawBang = false
        while true {
            if !sawTime, peek().type == .timeKw {
                sawTime = true
                let token = try next()
                prefix.append(Node(kind: .reservedWord(token.value),
                                   range: token.range))
                if peek().type == .timeOpt
                    || (peek().type == .word && peek().value == "-p") {
                    _ = try next()
                }
                if peek().type == .timeIgn
                    || (peek().type == .word && peek().value == "--") {
                    _ = try next()
                }
                continue
            }
            if !sawBang, peek().type == .bang {
                sawBang = true
                let token = try next()
                prefix.append(Node(kind: .reservedWord(token.value),
                                   range: token.range))
                continue
            }
            break
        }

        let pipe = try parsePipeline()
        guard !prefix.isEmpty else { return pipe }
        var parts: [Node]
        if case .pipeline(let existing) = pipe.kind {
            parts = prefix + existing
        } else {
            parts = prefix + [pipe]
        }
        return Node(kind: .pipeline(parts: parts), range: spanOf(parts))
    }

    func parsePipeline() throws -> Node {
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
}
