import Foundation

/// Parse a jq filter expression into a ``JqAST``.
public struct JqParser {
    private var tokens: [JqToken]
    private var pos = 0

    public static func parse(_ source: String) throws -> JqAST {
        var lexer = JqLexer(source)
        let toks = try lexer.tokenize()
        var p = JqParser(tokens: toks)
        let ast = try p.parseExpr()
        if !p.check(.eof) {
            throw JqError("jq: parse error: Unexpected token at position \(p.peek().pos)")
        }
        return ast
    }

    init(tokens: [JqToken]) {
        self.tokens = tokens
    }

    // MARK: - Token helpers

    private func peek(_ offset: Int = 0) -> JqToken {
        let i = pos + offset
        return i < tokens.count ? tokens[i] : JqToken(kind: .eof, pos: -1)
    }

    @discardableResult
    private mutating func advance() -> JqToken {
        defer { pos += 1 }
        return tokens[pos]
    }

    private func check(_ kind: JqTokenKind) -> Bool {
        peek().kind == kind
    }

    private mutating func match(_ kinds: JqTokenKind...) -> JqToken? {
        for k in kinds where check(k) {
            return advance()
        }
        return nil
    }

    private mutating func expect(_ kind: JqTokenKind, _ msg: String) throws -> JqToken {
        guard check(kind) else {
            throw JqError("jq: parse error: \(msg) at position \(peek().pos)")
        }
        return advance()
    }

    // MARK: - Grammar

    mutating func parseExpr() throws -> JqAST {
        try parsePipe()
    }

    private mutating func parsePipe() throws -> JqAST {
        var left = try parseComma()
        while match(.pipe) != nil {
            let right = try parseComma()
            left = .pipe(left, right)
        }
        return left
    }

    private mutating func parseComma() throws -> JqAST {
        var left = try parseVarBind()
        while match(.comma) != nil {
            let right = try parseVarBind()
            left = .comma(left, right)
        }
        return left
    }

    private mutating func parseVarBind() throws -> JqAST {
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

    private mutating func parsePattern() throws -> JqPattern {
        if match(.lbracket) != nil {
            var elems: [JqPattern] = []
            if !check(.rbracket) {
                elems.append(try parsePattern())
                while match(.comma) != nil {
                    if check(.rbracket) { break }
                    elems.append(try parsePattern())
                }
            }
            _ = try expect(.rbracket, "Expected ']' after array pattern")
            return .array(elems)
        }
        if match(.lbrace) != nil {
            var fields: [JqPatternField] = []
            if !check(.rbrace) {
                fields.append(try parsePatternField())
                while match(.comma) != nil {
                    if check(.rbrace) { break }
                    fields.append(try parsePatternField())
                }
            }
            _ = try expect(.rbrace, "Expected '}' after object pattern")
            return .object(fields)
        }
        // simple variable
        let tok = peek()
        if case .variable(let name) = tok.kind {
            advance()
            return .variable(name)
        }
        throw JqError("jq: parse error: Expected variable name in pattern at position \(tok.pos)")
    }

    private mutating func parsePatternField() throws -> JqPatternField {
        if match(.lparen) != nil {
            let keyExpr = try parseExpr()
            _ = try expect(.rparen, "Expected ')' after computed key")
            _ = try expect(.colon, "Expected ':' after computed key")
            let pattern = try parsePattern()
            return JqPatternField(key: .computed(keyExpr), pattern: pattern)
        }
        let tok = peek()
        // $name shorthand: {$foo} == {foo: $foo}; {$foo: pattern} ==
        // {foo: pattern, also bind $foo to value}
        if case .variable(let varName) = tok.kind {
            advance()
            if match(.colon) != nil {
                let pat = try parsePattern()
                return JqPatternField(key: .literal(String(varName.dropFirst())),
                                      pattern: pat,
                                      keyVar: varName)
            }
            return JqPatternField(key: .literal(String(varName.dropFirst())),
                                  pattern: .variable(varName))
        }
        // key (identifier / keyword) optionally followed by ': pattern'
        if let key = identLike(tok) {
            advance()
            if match(.colon) != nil {
                let pat = try parsePattern()
                return JqPatternField(key: .literal(key), pattern: pat)
            }
            return JqPatternField(key: .literal(key), pattern: .variable("$\(key)"))
        }
        throw JqError("jq: parse error: Expected field name in object pattern at position \(tok.pos)")
    }

    private mutating func parseUpdate() throws -> JqAST {
        let left = try parseAlt()
        let opMap: [JqTokenKind: JqUpdateOp] = [
            .assign: .assign, .updateAdd: .addAssign, .updateSub: .subAssign,
            .updateMul: .mulAssign, .updateDiv: .divAssign, .updateMod: .modAssign,
            .updateAlt: .altAssign, .updatePipe: .pipeAssign,
        ]
        for (kind, op) in opMap {
            if check(kind) {
                advance()
                let value = try parseVarBind()
                return .updateOp(op, path: left, value: value)
            }
        }
        return left
    }

    private mutating func parseAlt() throws -> JqAST {
        var left = try parseOr()
        while match(.alt) != nil {
            let right = try parseOr()
            left = .binaryOp(.alt, left, right)
        }
        return left
    }

    private mutating func parseOr() throws -> JqAST {
        var left = try parseAnd()
        while match(.or) != nil {
            let right = try parseAnd()
            left = .binaryOp(.or, left, right)
        }
        return left
    }

    private mutating func parseAnd() throws -> JqAST {
        var left = try parseComparison()
        while match(.and) != nil {
            let right = try parseComparison()
            left = .binaryOp(.and, left, right)
        }
        return left
    }

    private mutating func parseComparison() throws -> JqAST {
        let left = try parseAddSub()
        let opMap: [(JqTokenKind, JqBinaryOp)] = [
            (.eq, .eq), (.ne, .ne), (.lt, .lt), (.le, .le), (.gt, .gt), (.ge, .ge),
        ]
        for (k, op) in opMap where check(k) {
            advance()
            let right = try parseAddSub()
            return .binaryOp(op, left, right)
        }
        return left
    }

    private mutating func parseAddSub() throws -> JqAST {
        var left = try parseMulDiv()
        while true {
            if match(.plus) != nil {
                let right = try parseMulDiv()
                left = .binaryOp(.add, left, right)
            } else if match(.minus) != nil {
                let right = try parseMulDiv()
                left = .binaryOp(.sub, left, right)
            } else {
                break
            }
        }
        return left
    }

    private mutating func parseMulDiv() throws -> JqAST {
        var left = try parseUnary()
        while true {
            if match(.star) != nil {
                let r = try parseUnary(); left = .binaryOp(.mul, left, r)
            } else if match(.slash) != nil {
                let r = try parseUnary(); left = .binaryOp(.div, left, r)
            } else if match(.percent) != nil {
                let r = try parseUnary(); left = .binaryOp(.mod, left, r)
            } else { break }
        }
        return left
    }

    private mutating func parseUnary() throws -> JqAST {
        if match(.minus) != nil {
            let operand = try parseUnary()
            return .unaryOp(.neg, operand)
        }
        return try parsePostfix()
    }

    private mutating func parsePostfix() throws -> JqAST {
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

    private mutating func parsePrimary() throws -> JqAST {
        if match(.dotdot) != nil { return .recurse }
        if check(.dot) {
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
        if match(.true_) != nil { return .literal(.bool(true)) }
        if match(.false_) != nil { return .literal(.bool(false)) }
        if match(.null) != nil { return .literal(.null) }
        if case .number(let n) = peek().kind {
            advance(); return .literal(.number(n))
        }
        if case .string(let s) = peek().kind {
            advance()
            return Self.parseInterpolation(s)
        }
        // @format — followed optionally by a string for templated formatting
        if case .format(let name) = peek().kind {
            advance()
            if case .string(let s) = peek().kind {
                advance()
                let interp = Self.parseInterpolation(s)
                if case .stringInterp(let parts) = interp {
                    return .format(name: name, interp: parts)
                }
                return .format(name: name, interp: [.literal(s)])
            }
            return .format(name: name, interp: nil)
        }
        if match(.lbracket) != nil {
            if match(.rbracket) != nil { return .array(nil) }
            let elements = try parseExpr()
            _ = try expect(.rbracket, "Expected ']'")
            return .array(elements)
        }
        if match(.lbrace) != nil {
            return try parseObjectConstruction()
        }
        if match(.lparen) != nil {
            let e = try parseExpr()
            _ = try expect(.rparen, "Expected ')'")
            return .paren(e)
        }
        if match(.if_) != nil { return try parseIf() }
        if match(.try_) != nil {
            let body = try parsePostfix()
            var catch_: JqAST? = nil
            if match(.catch_) != nil {
                catch_ = try parsePostfix()
            }
            return .try_(body: body, catch_: catch_)
        }
        if match(.reduce) != nil {
            let expr = try parseAddSub()
            _ = try expect(.as_, "Expected 'as' after reduce expression")
            let pat = try parsePattern()
            _ = try expect(.lparen, "Expected '(' after pattern")
            let init_ = try parseExpr()
            _ = try expect(.semicolon, "Expected ';' after init")
            let update = try parseExpr()
            _ = try expect(.rparen, "Expected ')'")
            return .reduce(expr: expr, pattern: pat, init_: init_, update: update)
        }
        if match(.foreach) != nil {
            let expr = try parseAddSub()
            _ = try expect(.as_, "Expected 'as' after foreach expression")
            let pat = try parsePattern()
            _ = try expect(.lparen, "Expected '(' after pattern")
            let init_ = try parseExpr()
            _ = try expect(.semicolon, "Expected ';' after init")
            let update = try parseExpr()
            var extract: JqAST? = nil
            if match(.semicolon) != nil { extract = try parseExpr() }
            _ = try expect(.rparen, "Expected ')'")
            return .foreach(expr: expr, pattern: pat, init_: init_, update: update, extract: extract)
        }
        if match(.label) != nil {
            let tok = peek()
            guard case .variable(let name) = tok.kind else {
                throw JqError("jq: parse error: Expected label name (e.g., $out) at position \(tok.pos)")
            }
            advance()
            _ = try expect(.pipe, "Expected '|' after label name")
            let body = try parseExpr()
            return .label(name, body)
        }
        if match(.break_) != nil {
            let tok = peek()
            guard case .variable(let name) = tok.kind else {
                throw JqError("jq: parse error: Expected label name to break to at position \(tok.pos)")
            }
            advance()
            return .break_(name)
        }
        if match(.def) != nil {
            return try parseDef()
        }
        if match(.not_) != nil {
            return .call(name: "not", args: [])
        }
        // ident → call or var-ref
        if case .ident(let name) = peek().kind {
            advance()
            if match(.lparen) != nil {
                var args: [JqAST] = []
                if !check(.rparen) {
                    args.append(try parseExpr())
                    while match(.semicolon) != nil {
                        args.append(try parseExpr())
                    }
                }
                _ = try expect(.rparen, "Expected ')'")
                return .call(name: name, args: args)
            }
            return .call(name: name, args: [])
        }
        if case .variable(let name) = peek().kind {
            advance()
            return .varRef(name)
        }
        throw JqError("jq: parse error: Unexpected token at position \(peek().pos)")
    }

    private mutating func parseObjectConstruction() throws -> JqAST {
        var entries: [JqObjectEntry] = []
        if !check(.rbrace) {
            repeat {
                entries.append(try parseObjectEntry())
            } while match(.comma) != nil
        }
        _ = try expect(.rbrace, "Expected '}'")
        return .object(entries)
    }

    private mutating func parseObjectEntry() throws -> JqObjectEntry {
        // (expr): value
        if match(.lparen) != nil {
            let keyExpr = try parseExpr()
            _ = try expect(.rparen, "Expected ')'")
            _ = try expect(.colon, "Expected ':'")
            let v = try parseObjectValue()
            return JqObjectEntry(key: .computed(keyExpr), value: v)
        }
        let tok = peek()
        // "string": value
        if case .string(let s) = tok.kind {
            advance()
            _ = try expect(.colon, "Expected ':'")
            let v = try parseObjectValue()
            return JqObjectEntry(key: .literal(s), value: v)
        }
        // $foo shorthand: {$foo} == {foo: $foo}
        if case .variable(let varName) = tok.kind {
            advance()
            if match(.colon) != nil {
                let v = try parseObjectValue()
                return JqObjectEntry(key: .literal(String(varName.dropFirst())), value: v)
            }
            // shorthand: $foo means foo: $foo
            return JqObjectEntry(key: .literal(String(varName.dropFirst())),
                                 value: .varRef(varName))
        }
        // ident or keyword as key
        if let key = identLike(tok) {
            advance()
            if match(.colon) != nil {
                let v = try parseObjectValue()
                return JqObjectEntry(key: .literal(key), value: v)
            }
            // shorthand {key} == {key: .key}
            return JqObjectEntry(key: .literal(key),
                                 value: .field(name: key, base: nil))
        }
        throw JqError("jq: parse error: Expected object key at position \(tok.pos)")
    }

    /// Object values allow pipes but stop at comma — comma separates
    /// entries, not pipeline elements.
    private mutating func parseObjectValue() throws -> JqAST {
        var left = try parseVarBind()
        while match(.pipe) != nil {
            let right = try parseVarBind()
            left = .pipe(left, right)
        }
        return left
    }

    private mutating func parseIf() throws -> JqAST {
        let cond = try parseExpr()
        _ = try expect(.then, "Expected 'then'")
        let then = try parseExpr()
        var elifs: [(JqAST, JqAST)] = []
        while match(.elif) != nil {
            let c = try parseExpr()
            _ = try expect(.then, "Expected 'then' after elif")
            let t = try parseExpr()
            elifs.append((c, t))
        }
        var else_: JqAST? = nil
        if match(.else_) != nil {
            else_ = try parseExpr()
        }
        _ = try expect(.end, "Expected 'end'")
        return .cond(cond: cond, then: then, elifs: elifs, else_: else_)
    }

    private mutating func parseDef() throws -> JqAST {
        let nameTok = peek()
        guard case .ident(let name) = nameTok.kind else {
            throw JqError("jq: parse error: Expected function name after def at position \(nameTok.pos)")
        }
        advance()
        var params: [String] = []
        if match(.lparen) != nil {
            if !check(.rparen) {
                let t = peek()
                guard case .ident(let p1) = t.kind else {
                    throw JqError("jq: parse error: Expected parameter name at position \(t.pos)")
                }
                advance()
                params.append(p1)
                while match(.semicolon) != nil {
                    let t2 = peek()
                    guard case .ident(let pn) = t2.kind else {
                        throw JqError("jq: parse error: Expected parameter name at position \(t2.pos)")
                    }
                    advance()
                    params.append(pn)
                }
            }
            _ = try expect(.rparen, "Expected ')' after parameters")
        }
        _ = try expect(.colon, "Expected ':' after function name")
        let funcBody = try parseExpr()
        _ = try expect(.semicolon, "Expected ';' after function body")
        let body = try parseExpr()
        return .def(name: name, params: params, funcBody: funcBody, body: body)
    }

    // MARK: - Helpers

    private func identLike(_ tok: JqToken) -> String? {
        switch tok.kind {
        case .ident(let s): return s
        case .and: return "and"
        case .or: return "or"
        case .not_: return "not"
        case .if_: return "if"
        case .then: return "then"
        case .elif: return "elif"
        case .else_: return "else"
        case .end: return "end"
        case .as_: return "as"
        case .try_: return "try"
        case .catch_: return "catch"
        case .true_: return "true"
        case .false_: return "false"
        case .null: return "null"
        case .reduce: return "reduce"
        case .foreach: return "foreach"
        case .label: return "label"
        case .break_: return "break"
        case .def: return "def"
        default: return nil
        }
    }

    /// Return the field-name string from a token at position
    /// `dotPos + 1`. Identifiers, jq keywords, and quoted strings all
    /// count.
    private func fieldName(from tok: JqToken, dotPos: Int) -> String? {
        if case .string(let s) = tok.kind { return s }
        return identLike(tok)
    }

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

    /// Parse a string literal whose body may contain `\(expr)`
    /// interpolations. The lexer preserves `\(` literally so we
    /// re-tokenize the inner expression here.
    static func parseInterpolation(_ raw: String) -> JqAST {
        if !raw.contains("\\(") {
            return .literal(.string(raw))
        }
        var parts: [JqStringPart] = []
        var current = ""
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count && chars[i + 1] == "(" {
                if !current.isEmpty {
                    parts.append(.literal(current))
                    current = ""
                }
                i += 2
                var depth = 1
                var inner = ""
                while i < chars.count && depth > 0 {
                    if chars[i] == "(" { depth += 1 }
                    else if chars[i] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    inner.append(chars[i])
                    i += 1
                }
                if i < chars.count { i += 1 }  // consume ')'
                if let ast = try? JqParser.parse(inner) {
                    parts.append(.interp(ast))
                }
            } else {
                current.append(chars[i])
                i += 1
            }
        }
        if !current.isEmpty { parts.append(.literal(current)) }
        return .stringInterp(parts)
    }
}
