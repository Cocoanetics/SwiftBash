import Foundation

// MARK: - Statement-level parsers split out of `JqParser` to keep its body lean.

extension JqParser {
    mutating func parsePrimaryReduce() throws -> JqAST {
        let expr = try parseAddSub()
        _ = try expect(.as_, "Expected 'as' after reduce expression")
        let pat = try parsePattern()
        _ = try expect(.lparen, "Expected '(' after pattern")
        // swiftlint:disable:next identifier_name - mirrors jq keyword `init`
        let init_ = try parseExpr()
        _ = try expect(.semicolon, "Expected ';' after init")
        let update = try parseExpr()
        _ = try expect(.rparen, "Expected ')'")
        return .reduce(expr: expr, pattern: pat, init_: init_, update: update)
    }

    mutating func parsePrimaryForeach() throws -> JqAST {
        let expr = try parseAddSub()
        _ = try expect(.as_, "Expected 'as' after foreach expression")
        let pat = try parsePattern()
        _ = try expect(.lparen, "Expected '(' after pattern")
        // swiftlint:disable:next identifier_name - mirrors jq keyword `init`
        let init_ = try parseExpr()
        _ = try expect(.semicolon, "Expected ';' after init")
        let update = try parseExpr()
        var extract: JqAST?
        if match(.semicolon) != nil { extract = try parseExpr() }
        _ = try expect(.rparen, "Expected ')'")
        return .foreach(expr: expr, pattern: pat, init_: init_, update: update, extract: extract)
    }

    mutating func parsePrimaryLabel() throws -> JqAST {
        let tok = peek()
        guard case .variable(let name) = tok.kind else {
            throw JqError("jq: parse error: Expected label name (e.g., $out) at position \(tok.pos)")
        }
        advance()
        _ = try expect(.pipe, "Expected '|' after label name")
        let body = try parseExpr()
        return .label(name, body)
    }

    mutating func parsePrimaryBreak() throws -> JqAST {
        let tok = peek()
        guard case .variable(let name) = tok.kind else {
            throw JqError("jq: parse error: Expected label name to break to at position \(tok.pos)")
        }
        advance()
        return .break_(name)
    }

    mutating func parsePrimaryIdent() throws -> JqAST {
        guard case .ident(let name) = peek().kind else {
            throw JqError("jq: parse error: Unexpected token at position \(peek().pos)")
        }
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

    mutating func parseIf() throws -> JqAST {
        let cond = try parseExpr()
        _ = try expect(.then, "Expected 'then'")
        let then = try parseExpr()
        var elifs: [(JqAST, JqAST)] = []
        while match(.elif) != nil {
            let elifCond = try parseExpr()
            _ = try expect(.then, "Expected 'then' after elif")
            let elifThen = try parseExpr()
            elifs.append((elifCond, elifThen))
        }
        // swiftlint:disable:next identifier_name - mirrors jq keyword `else`
        var else_: JqAST?
        if match(.else_) != nil {
            else_ = try parseExpr()
        }
        _ = try expect(.end, "Expected 'end'")
        return .cond(cond: cond, then: then, elifs: elifs, else_: else_)
    }

    mutating func parseDef() throws -> JqAST {
        let nameTok = peek()
        guard case .ident(let name) = nameTok.kind else {
            throw JqError("jq: parse error: Expected function name after def at position \(nameTok.pos)")
        }
        advance()
        var params: [String] = []
        if match(.lparen) != nil {
            if !check(.rparen) {
                let firstTok = peek()
                guard case .ident(let firstName) = firstTok.kind else {
                    throw JqError("jq: parse error: Expected parameter name at position \(firstTok.pos)")
                }
                advance()
                params.append(firstName)
                while match(.semicolon) != nil {
                    let nextTok = peek()
                    guard case .ident(let nextName) = nextTok.kind else {
                        throw JqError("jq: parse error: Expected parameter name at position \(nextTok.pos)")
                    }
                    advance()
                    params.append(nextName)
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
}
