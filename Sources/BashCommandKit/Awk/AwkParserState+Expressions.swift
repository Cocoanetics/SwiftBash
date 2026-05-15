import Foundation

// AwkParserState extension carrying the expression-parsing methods.
// Primary/print-context parsing lives in
// `AwkParserState+Primary.swift`.
extension AwkParserState {

    // MARK: expression — precedence climbing

    mutating func parseExpression(inPrint: Bool) throws -> AwkExpr {
        try parseAssignment(inPrint: inPrint)
    }

    mutating func parseAssignment(inPrint: Bool) throws -> AwkExpr {
        let lhs = try parseTernary(inPrint: inPrint)
        if let assignOp = currentAssignOp() {
            advance()
            let rhs = try parseAssignment(inPrint: inPrint)
            let target = try lvalueFromExpr(lhs)
            return .assignment(assignOp, target: target, value: rhs)
        }
        return lhs
    }

    func currentAssignOp() -> AwkAssignOp? {
        switch peek().kind {
        case .assign: return .assign
        case .plusAssign: return .addAssign
        case .minusAssign: return .subAssign
        case .starAssign: return .mulAssign
        case .slashAssign: return .divAssign
        case .percentAssign: return .modAssign
        case .caretAssign: return .powAssign
        default: return nil
        }
    }

    mutating func parseTernary(inPrint: Bool) throws -> AwkExpr {
        let cond = try parsePipeGetline(inPrint: inPrint)
        if check(.question) {
            advance()
            let then = try parseExpression(inPrint: inPrint)
            _ = try expect(.colon, "expected ':' in ternary")
            let alt = try parseExpression(inPrint: inPrint)
            return .ternary(cond, then, alt)
        }
        return cond
    }

    mutating func parsePipeGetline(inPrint: Bool) throws -> AwkExpr {
        let left = try parseOr(inPrint: inPrint)
        // `expr | getline [var]` — only outside print context (in
        // print, `|` is redirection).
        if !inPrint, check(.pipe) {
            advance()
            guard check(.kGetline) else {
                throw AwkParseError("expected 'getline' after '|'")
            }
            advance()
            var varName: String?
            if case .ident(let name) = peek().kind {
                advance()
                varName = name
            }
            return .getline(variable: varName, file: nil, command: left)
        }
        return left
    }

    mutating func parseOr(inPrint: Bool) throws -> AwkExpr {
        var lhs = try parseAnd(inPrint: inPrint)
        while check(.or) {
            advance()
            let rhs = try parseAnd(inPrint: inPrint)
            lhs = .binary(.or, lhs, rhs)
        }
        return lhs
    }

    mutating func parseAnd(inPrint: Bool) throws -> AwkExpr {
        var lhs = try parseIn(inPrint: inPrint)
        while check(.and) {
            advance()
            let rhs = try parseIn(inPrint: inPrint)
            lhs = .binary(.and, lhs, rhs)
        }
        return lhs
    }

    mutating func parseLogicalOrRest(left: AwkExpr) throws -> AwkExpr {
        var lhs = left
        while check(.and) {
            advance()
            let rhs = try parseIn(inPrint: false)
            lhs = .binary(.and, lhs, rhs)
        }
        while check(.or) {
            advance()
            let rhs = try parseAnd(inPrint: false)
            lhs = .binary(.or, lhs, rhs)
        }
        return lhs
    }

    mutating func parseIn(inPrint: Bool) throws -> AwkExpr {
        let lhs = try parseConcatenation(inPrint: inPrint)
        if check(.kIn) {
            advance()
            let arr = try identName()
            return .inExpr(key: lhs, array: arr)
        }
        return lhs
    }

    mutating func parseConcatenation(inPrint: Bool) throws -> AwkExpr {
        var lhs = try parseMatch(inPrint: inPrint)
        while canStartExpression() && !isConcatTerminator(inPrint: inPrint) {
            let rhs = try parseMatch(inPrint: inPrint)
            lhs = .binary(.concat, lhs, rhs)
        }
        return lhs
    }

    func canStartExpression() -> Bool {
        switch peek().kind {
        case .number, .string, .ident, .dollar, .lparen,
             .not, .minus, .plus, .increment, .decrement:
            return true
        default: return false
        }
    }

    func isConcatTerminator(inPrint: Bool) -> Bool {
        switch peek().kind {
        case .and, .or, .question,
             .assign, .plusAssign, .minusAssign, .starAssign, .slashAssign, .percentAssign, .caretAssign,
             .comma, .semicolon, .newline, .rbrace, .rparen, .rbracket, .colon,
             .pipe, .append, .kIn, .eof:
            return true
        case .gt:
            return inPrint    // > is redirection in print context
        default:
            return false
        }
    }

    mutating func parseMatch(inPrint: Bool) throws -> AwkExpr {
        var lhs = try parseComparison(inPrint: inPrint)
        while match(.match, .notMatch) {
            let binOp: AwkBinaryOp = check(.match) ? .match : .notMatch
            advance()
            let rhs = try parseComparison(inPrint: inPrint)
            lhs = .binary(binOp, lhs, rhs)
        }
        return lhs
    }

    mutating func parseComparison(inPrint: Bool) throws -> AwkExpr {
        var lhs = try parseAddSub()
        while true {
            let binOp: AwkBinaryOp?
            switch peek().kind {
            case .lt: binOp = .lt
            case .le: binOp = .le
            case .gt where !inPrint: binOp = .gt
            case .ge: binOp = .ge
            case .eq: binOp = .eq
            case .ne: binOp = .ne
            default: binOp = nil
            }
            guard let binOp else { break }
            advance()
            let rhs = try parseAddSub()
            lhs = .binary(binOp, lhs, rhs)
        }
        return lhs
    }

    mutating func parseAddSub() throws -> AwkExpr {
        var lhs = try parseMulDiv()
        while match(.plus, .minus) {
            let binOp: AwkBinaryOp = check(.plus) ? .add : .sub
            advance()
            let rhs = try parseMulDiv()
            lhs = .binary(binOp, lhs, rhs)
        }
        return lhs
    }

    mutating func parseMulDiv() throws -> AwkExpr {
        var lhs = try parseUnary()
        while match(.star, .slash, .percent) {
            let binOp: AwkBinaryOp
            switch peek().kind {
            case .star: binOp = .mul
            case .slash: binOp = .div
            default: binOp = .mod
            }
            advance()
            let rhs = try parseUnary()
            lhs = .binary(binOp, lhs, rhs)
        }
        return lhs
    }

    mutating func parseUnary() throws -> AwkExpr {
        if check(.increment) {
            advance()
            let operand = try parseUnary()
            if let lvalue = try? lvalueFromExpr(operand) { return .preIncrement(lvalue) }
            return .unary(.pos, .unary(.pos, operand))
        }
        if check(.decrement) {
            advance()
            let operand = try parseUnary()
            if let lvalue = try? lvalueFromExpr(operand) { return .preDecrement(lvalue) }
            return .unary(.neg, .unary(.neg, operand))
        }
        if match(.not, .minus, .plus) {
            let unaryOp: AwkUnaryOp
            switch peek().kind {
            case .not: unaryOp = .not
            case .minus: unaryOp = .neg
            default: unaryOp = .pos
            }
            advance()
            let operand = try parseUnary()
            return .unary(unaryOp, operand)
        }
        return try parsePower()
    }

    mutating func parsePower() throws -> AwkExpr {
        let lhs = try parsePostfix()
        if check(.caret) {
            advance()
            let rhs = try parsePower()    // right-associative
            return .binary(.pow, lhs, rhs)
        }
        return lhs
    }

    mutating func parsePostfix() throws -> AwkExpr {
        let expr = try parsePrimary(inPrint: false)
        if check(.increment) {
            advance()
            let lvalue = try lvalueFromExpr(expr)
            return .postIncrement(lvalue)
        }
        if check(.decrement) {
            advance()
            let lvalue = try lvalueFromExpr(expr)
            return .postDecrement(lvalue)
        }
        return expr
    }
}
