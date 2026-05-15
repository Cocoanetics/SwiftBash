import Foundation

/// Parse a jq filter expression into a ``JqAST``.
public struct JqParser {
    private var tokens: [JqToken]
    private var pos = 0

    public static func parse(_ source: String) throws -> JqAST {
        var lexer = JqLexer(source)
        let toks = try lexer.tokenize()
        var parser = JqParser(tokens: toks)
        let ast = try parser.parseExpr()
        if !parser.check(.eof) {
            throw JqError("jq: parse error: Unexpected token at position \(parser.peek().pos)")
        }
        return ast
    }

    init(tokens: [JqToken]) {
        self.tokens = tokens
    }

    // MARK: - Token helpers

    func peek(_ offset: Int = 0) -> JqToken {
        let idx = pos + offset
        return idx < tokens.count ? tokens[idx] : JqToken(kind: .eof, pos: -1)
    }

    @discardableResult
    mutating func advance() -> JqToken {
        defer { pos += 1 }
        return tokens[pos]
    }

    func check(_ kind: JqTokenKind) -> Bool {
        peek().kind == kind
    }

    mutating func match(_ kinds: JqTokenKind...) -> JqToken? {
        for kind in kinds where check(kind) {
            return advance()
        }
        return nil
    }

    mutating func expect(_ kind: JqTokenKind, _ msg: String) throws -> JqToken {
        guard check(kind) else {
            throw JqError("jq: parse error: \(msg) at position \(peek().pos)")
        }
        return advance()
    }

    // MARK: - Grammar

    mutating func parseExpr() throws -> JqAST {
        try parsePipe()
    }

    mutating func parsePipe() throws -> JqAST {
        var left = try parseComma()
        while match(.pipe) != nil {
            let right = try parseComma()
            left = .pipe(left, right)
        }
        return left
    }

    mutating func parseComma() throws -> JqAST {
        var left = try parseVarBind()
        while match(.comma) != nil {
            let right = try parseVarBind()
            left = .comma(left, right)
        }
        return left
    }

    mutating func parseVarBind() throws -> JqAST {
        let expr = try parseUpdate()
        if match(.as_) != nil {
            let pattern = try parsePattern()
            var alternatives: [JqPattern] = []
            while check(.question) && peek(1).kind == .alt {
                advance(); advance()
                alternatives.append(try parsePattern())
            }
            _ = try expect(.pipe, "Expected '|' after variable binding")
            let body = try parseExpr()
            return .varBind(pattern: pattern, alternatives: alternatives, value: expr, body: body)
        }
        return expr
    }

    // `parsePattern` and `parsePatternField` live in
    // `JqParser+Patterns.swift`.

    mutating func parseUpdate() throws -> JqAST {
        let left = try parseAlt()
        let opMap: [JqTokenKind: JqUpdateOp] = [
            .assign: .assign, .updateAdd: .addAssign, .updateSub: .subAssign,
            .updateMul: .mulAssign, .updateDiv: .divAssign, .updateMod: .modAssign,
            .updateAlt: .altAssign, .updatePipe: .pipeAssign
        ]
        for (kind, oper) in opMap where check(kind) {
            advance()
            let value = try parseVarBind()
            return .updateOp(oper, path: left, value: value)
        }
        return left
    }

    // Binary operator precedence chain (parseAlt, parseOr, parseAnd,
    // parseComparison, parseAddSub, parseMulDiv, parseUnary) lives in
    // `JqParser+BinaryOps.swift`.

    mutating func parsePostfix() throws -> JqAST {
        var expr = try parsePrimary()
        while true {
            if match(.question) != nil {
                expr = .optional(expr)
                continue
            }
            // .field — must be adjacent to dot to count as a field;
            // a space before the identifier means a separate primary.
            if check(.dot) && isFieldNameAfterDot(at: 0) {
                let dotTok = advance()
                let nameTok = advance()
                let name = fieldName(from: nameTok, dotPos: dotTok.pos)!
                expr = .field(name: name, base: expr)
                continue
            }
            if check(.lbracket) {
                advance()
                if match(.rbracket) != nil {
                    expr = .iterate(base: expr)
                    continue
                }
                if check(.colon) {
                    advance()
                    let end: JqAST? = check(.rbracket) ? nil : try parseExpr()
                    _ = try expect(.rbracket, "Expected ']'")
                    expr = .slice(start: nil, end: end, base: expr)
                    continue
                }
                let idx = try parseExpr()
                if match(.colon) != nil {
                    let end: JqAST? = check(.rbracket) ? nil : try parseExpr()
                    _ = try expect(.rbracket, "Expected ']'")
                    expr = .slice(start: idx, end: end, base: expr)
                } else {
                    _ = try expect(.rbracket, "Expected ']'")
                    expr = .index(index: idx, base: expr)
                }
                continue
            }
            break
        }
        return expr
    }

    // swiftlint:disable:next cyclomatic_complexity - dispatches over many primary forms
    mutating func parsePrimary() throws -> JqAST {
        if match(.dotdot) != nil { return .recurse }
        if check(.dot) { return try parsePrimaryDot() }
        if let lit = matchLiteralAtom() { return lit }
        if case .number = peek().kind { return parsePrimaryNumber() }
        if case .string = peek().kind { return parsePrimaryString() }
        if case .format = peek().kind { return parsePrimaryFormat() }
        if match(.lbracket) != nil {
            if match(.rbracket) != nil { return .array(nil) }
            let elements = try parseExpr()
            _ = try expect(.rbracket, "Expected ']'")
            return .array(elements)
        }
        if match(.lbrace) != nil { return try parseObjectConstruction() }
        if match(.lparen) != nil {
            let expr = try parseExpr()
            _ = try expect(.rparen, "Expected ')'")
            return .paren(expr)
        }
        if match(.if_) != nil { return try parseIf() }
        if match(.try_) != nil { return try parsePrimaryTry() }
        if match(.reduce) != nil { return try parsePrimaryReduce() }
        if match(.foreach) != nil { return try parsePrimaryForeach() }
        if match(.label) != nil { return try parsePrimaryLabel() }
        if match(.break_) != nil { return try parsePrimaryBreak() }
        if match(.def) != nil { return try parseDef() }
        if match(.not_) != nil { return .call(name: "not", args: []) }
        if case .ident = peek().kind { return try parsePrimaryIdent() }
        if case .variable(let name) = peek().kind {
            advance(); return .varRef(name)
        }
        throw JqError("jq: parse error: Unexpected token at position \(peek().pos)")
    }

    mutating func parsePrimaryDot() throws -> JqAST {
        let dotTok = advance()
        // .[]  .[n]  .[s:e]
        if check(.lbracket) {
            advance()
            if match(.rbracket) != nil { return .iterate(base: nil) }
            if check(.colon) {
                advance()
                let end: JqAST? = check(.rbracket) ? nil : try parseExpr()
                _ = try expect(.rbracket, "Expected ']'")
                return .slice(start: nil, end: end, base: nil)
            }
            let idx = try parseExpr()
            if match(.colon) != nil {
                let end: JqAST? = check(.rbracket) ? nil : try parseExpr()
                _ = try expect(.rbracket, "Expected ']'")
                return .slice(start: idx, end: end, base: nil)
            }
            _ = try expect(.rbracket, "Expected ']'")
            return .index(index: idx, base: nil)
        }
        // .field or ."quoted"
        if isFieldNameAfterDot(at: -1) {
            let nameTok = advance()
            let name = fieldName(from: nameTok, dotPos: dotTok.pos)!
            return .field(name: name, base: nil)
        }
        return .identity
    }

    private mutating func matchLiteralAtom() -> JqAST? {
        if match(.true_) != nil { return .literal(.bool(true)) }
        if match(.false_) != nil { return .literal(.bool(false)) }
        if match(.null) != nil { return .literal(.null) }
        return nil
    }

    mutating func parsePrimaryNumber() -> JqAST {
        if case .number(let num) = peek().kind {
            advance(); return .literal(.number(num))
        }
        return .literal(.null)
    }

    mutating func parsePrimaryString() -> JqAST {
        if case .string(let str) = peek().kind {
            advance()
            return Self.parseInterpolation(str)
        }
        return .literal(.null)
    }

    mutating func parsePrimaryFormat() -> JqAST {
        // @format — followed optionally by a string for templated formatting
        guard case .format(let name) = peek().kind else { return .literal(.null) }
        advance()
        if case .string(let str) = peek().kind {
            advance()
            let interp = Self.parseInterpolation(str)
            if case .stringInterp(let parts) = interp {
                return .format(name: name, interp: parts)
            }
            return .format(name: name, interp: [.literal(str)])
        }
        return .format(name: name, interp: nil)
    }

    mutating func parsePrimaryTry() throws -> JqAST {
        let body = try parsePostfix()
        // swiftlint:disable:next identifier_name - mirrors jq keyword `catch`
        var catch_: JqAST?
        if match(.catch_) != nil {
            catch_ = try parsePostfix()
        }
        return .try_(body: body, catch_: catch_)
    }

    // `parsePrimaryReduce`, `parsePrimaryForeach`, `parsePrimaryLabel`,
    // `parsePrimaryBreak`, `parsePrimaryIdent`, `parseIf`, and `parseDef`
    // live in `JqParser+Statements.swift`.

    // Object construction parsing lives in `JqParser+Objects.swift`.

    // MARK: - Helpers

    /// Adjacency check: `.foo` is a field but `. foo` is identity then
    /// a separate identifier.  ``offset == 0`` looks at the dot at the
    /// current position; ``offset == -1`` after we've already consumed
    /// the dot.
    private func isFieldNameAfterDot(at offset: Int) -> Bool {
        let dot = peek(offset)
        let next = peek(offset + 1)
        if case .string = next.kind { return true }
        if identLike(next) != nil {
            return next.pos == dot.pos + 1
        }
        return false
    }

    // `identLike`, `fieldName`, and `parseInterpolation` live in
    // `JqParser+Helpers.swift`.
}
