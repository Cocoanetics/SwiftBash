import Foundation

// Internal mutable state for the recursive-descent AWK parser. Hosted
// in its own file so AwkParser.swift can stay below the file_length
// limit. Only AwkParser.parse(_:) constructs and uses this type.
//
// Reason: full parser logic lives in one nested state type.
// swiftlint:disable:next type_body_length
struct AwkParserState {
    var tokens: [AwkToken]
    var pos = 0

    // MARK: token helpers
    func peek(_ offset: Int = 0) -> AwkToken {
        let idx = pos + offset
        return idx < tokens.count ? tokens[idx] : tokens[tokens.count - 1]
    }
    @discardableResult mutating func advance() -> AwkToken {
        defer { pos += 1 }
        return tokens[pos]
    }
    func check(_ kind: AwkTokenKind) -> Bool { peek().kind == kind }
    mutating func match(_ kinds: AwkTokenKind...) -> Bool {
        for kind in kinds where check(kind) { return true }
        return false
    }
    mutating func expect(_ kind: AwkTokenKind, _ msg: String) throws -> AwkToken {
        guard check(kind) else {
            throw AwkParseError("\(msg) at line \(peek().line):\(peek().column) — got \(peek().kind)")
        }
        return advance()
    }
    mutating func skipNewlines() {
        while check(.newline) { advance() }
    }
    mutating func skipTerminators() {
        while check(.newline) || check(.semicolon) { advance() }
    }
    var atEnd: Bool { check(.eof) }

    // MARK: program

    mutating func parseProgram() throws -> AwkProgram {
        var program = AwkProgram()
        skipNewlines()
        while !atEnd {
            skipNewlines()
            if atEnd { break }
            if check(.kFunction) {
                program.functions.append(try parseFunction())
            } else {
                program.rules.append(try parseRule())
            }
            skipTerminators()
        }
        return program
    }

    mutating func parseFunction() throws -> AwkFunction {
        _ = try expect(.kFunction, "expected 'function'")
        let name = try identName()
        _ = try expect(.lparen, "expected '(' after function name")
        var params: [String] = []
        if !check(.rparen) {
            params.append(try identName())
            while check(.comma) { advance(); params.append(try identName()) }
        }
        _ = try expect(.rparen, "expected ')' after parameters")
        skipNewlines()
        let body = try parseBlock()
        return AwkFunction(name: name, params: params, body: body)
    }

    mutating func identName() throws -> String {
        let tok = peek()
        guard case .ident(let name) = tok.kind else {
            throw AwkParseError("expected identifier at line \(tok.line):\(tok.column)")
        }
        advance()
        return name
    }

    mutating func parseRule() throws -> AwkRule {
        var pattern: AwkPattern?
        if check(.kBegin) {
            advance(); pattern = .begin
        } else if check(.kEnd) {
            advance(); pattern = .end
        } else if check(.lbrace) {
            pattern = nil   // bare action
        } else if case .regex(let pat) = peek().kind {
            advance()
            if check(.and) || check(.or) {
                let regexExpr = AwkExpr.binary(.match,
                                               .field(.number(0)),
                                               .regex(pat))
                let full = try parseLogicalOrRest(left: regexExpr)
                pattern = .expr(full)
            } else {
                let pat = AwkPattern.regex(pat)
                if check(.comma) {
                    advance()
                    let end = try parsePatternForRange()
                    pattern = .range(start: pat, end: end)
                } else {
                    pattern = pat
                }
            }
        } else {
            let expr = try parseExpression(inPrint: false)
            let pat = AwkPattern.expr(expr)
            if check(.comma) {
                advance()
                let end = try parsePatternForRange()
                pattern = .range(start: pat, end: end)
            } else {
                pattern = pat
            }
        }
        skipNewlines()
        var action: [AwkStmt] = []
        if check(.lbrace) {
            action = try parseBlock()
        } else {
            // Default action: print $0
            action = [.print(args: [.field(.number(0))], output: nil)]
        }
        return AwkRule(pattern: pattern, action: action)
    }

    mutating func parsePatternForRange() throws -> AwkPattern {
        if case .regex(let pat) = peek().kind {
            advance()
            return .regex(pat)
        }
        return .expr(try parseExpression(inPrint: false))
    }

    mutating func parseBlock() throws -> [AwkStmt] {
        _ = try expect(.lbrace, "expected '{'")
        skipNewlines()
        var stmts: [AwkStmt] = []
        while !check(.rbrace) && !atEnd {
            stmts.append(try parseStatement())
            skipTerminators()
        }
        _ = try expect(.rbrace, "expected '}'")
        return stmts
    }

    // MARK: statement

    // swiftlint:disable:next cyclomatic_complexity
    mutating func parseStatement() throws -> AwkStmt {
        if check(.semicolon) || check(.newline) {
            advance()
            return .block([])
        }
        if check(.lbrace) { return .block(try parseBlock()) }
        if check(.kIf) { return try parseIf() }
        if check(.kWhile) { return try parseWhile() }
        if check(.kDo) { return try parseDoWhile() }
        if check(.kFor) { return try parseFor() }
        if check(.kBreak) { advance(); return .break_ }
        if check(.kContinue) { advance(); return .continue_ }
        if check(.kNext) { advance(); return .next }
        if check(.kNextfile) { advance(); return .nextfile }
        if check(.kExit) {
            advance()
            let code: AwkExpr? = isStmtTerm() ? nil : try parseExpression(inPrint: false)
            return .exit(code: code)
        }
        if check(.kReturn) {
            advance()
            let val: AwkExpr? = isStmtTerm() ? nil : try parseExpression(inPrint: false)
            return .return_(value: val)
        }
        if check(.kDelete) {
            advance()
            // Re-use primary parsing for the target.
            let prim = try parsePrimary(inPrint: false)
            let target = try lvalueFromExpr(prim)
            return .delete(target: target)
        }
        if check(.kPrint) { return try parsePrintStatement() }
        if check(.kPrintf) { return try parsePrintfStatement() }
        let expr = try parseExpression(inPrint: false)
        return .exprStmt(expr)
    }

    func isStmtTerm() -> Bool {
        switch peek().kind {
        case .newline, .semicolon, .rbrace, .eof: return true
        default: return false
        }
    }

    func lvalueFromExpr(_ expr: AwkExpr) throws -> AwkLValue {
        switch expr {
        case .variable(let name): return .variable(name)
        case .field(let idx): return .field(idx)
        case .arrayAccess(let name, let key): return .arrayAccess(name: name, key: key)
        default: throw AwkParseError("invalid assignment target")
        }
    }

    mutating func parseIf() throws -> AwkStmt {
        _ = try expect(.kIf, "expected 'if'")
        _ = try expect(.lparen, "expected '('")
        let cond = try parseExpression(inPrint: false)
        _ = try expect(.rparen, "expected ')'")
        skipNewlines()
        let consequent = try parseStatement()
        skipTerminators()
        var alt: AwkStmt?
        if check(.kElse) {
            advance()
            skipNewlines()
            alt = try parseStatement()
        }
        return .ifStmt(cond: cond, then: consequent, else_: alt)
    }

    mutating func parseWhile() throws -> AwkStmt {
        advance()
        _ = try expect(.lparen, "expected '('")
        let cond = try parseExpression(inPrint: false)
        _ = try expect(.rparen, "expected ')'")
        skipNewlines()
        let body = try parseStatement()
        return .whileStmt(cond: cond, body: body)
    }

    mutating func parseDoWhile() throws -> AwkStmt {
        advance()
        skipNewlines()
        let body = try parseStatement()
        skipNewlines()
        _ = try expect(.kWhile, "expected 'while'")
        _ = try expect(.lparen, "expected '('")
        let cond = try parseExpression(inPrint: false)
        _ = try expect(.rparen, "expected ')'")
        return .doWhile(body: body, cond: cond)
    }

    mutating func parseFor() throws -> AwkStmt {
        advance()
        _ = try expect(.lparen, "expected '('")
        // for (var in array)?
        if case .ident(let name) = peek().kind {
            advance()
            if check(.kIn) {
                advance()
                let arr = try identName()
                _ = try expect(.rparen, "expected ')'")
                skipNewlines()
                let body = try parseStatement()
                return .forIn(variable: name, array: arr, body: body)
            }
            pos -= 1   // backtrack
        }
        var initE: AwkExpr?
        if !check(.semicolon) {
            initE = try parseExpression(inPrint: false)
        }
        _ = try expect(.semicolon, "expected ';' after for-init")
        var condE: AwkExpr?
        if !check(.semicolon) {
            condE = try parseExpression(inPrint: false)
        }
        _ = try expect(.semicolon, "expected ';' after for-cond")
        var updE: AwkExpr?
        if !check(.rparen) {
            updE = try parseExpression(inPrint: false)
        }
        _ = try expect(.rparen, "expected ')'")
        skipNewlines()
        let body = try parseStatement()
        return .forStmt(init_: initE, cond: condE, update: updE, body: body)
    }

    mutating func parsePrintStatement() throws -> AwkStmt {
        _ = try expect(.kPrint, "expected 'print'")
        var args: [AwkExpr] = []
        if isPrintEnd() {
            args.append(.field(.number(0)))
        } else {
            args.append(try parsePrintArg())
            while check(.comma) {
                advance()
                args.append(try parsePrintArg())
            }
        }
        let output = try parseRedirection()
        return .print(args: args, output: output)
    }

    mutating func parsePrintfStatement() throws -> AwkStmt {
        _ = try expect(.kPrintf, "expected 'printf'")
        let hasParens = check(.lparen)
        if hasParens { advance(); skipNewlines() }
        let format: AwkExpr
        var argList: [AwkExpr] = []
        if hasParens {
            format = try parseExpression(inPrint: false)
            while check(.comma) {
                advance()
                skipNewlines()
                argList.append(try parseExpression(inPrint: false))
            }
            skipNewlines()
            _ = try expect(.rparen, "expected ')'")
        } else {
            format = try parsePrintArg()
            while check(.comma) {
                advance()
                argList.append(try parsePrintArg())
            }
        }
        let output = try parseRedirection()
        return .printf(format: format, args: argList, output: output)
    }

    mutating func parseRedirection() throws -> AwkOutput? {
        if check(.gt) {
            advance()
            return AwkOutput(kind: .write, target: try parsePrimary(inPrint: false))
        }
        if check(.append) {
            advance()
            return AwkOutput(kind: .append, target: try parsePrimary(inPrint: false))
        }
        if check(.pipe) {
            advance()
            return AwkOutput(kind: .pipe, target: try parsePrimary(inPrint: false))
        }
        return nil
    }

    func isPrintEnd() -> Bool {
        switch peek().kind {
        case .newline, .semicolon, .rbrace, .pipe, .gt, .append, .eof: return true
        default: return false
        }
    }
}
