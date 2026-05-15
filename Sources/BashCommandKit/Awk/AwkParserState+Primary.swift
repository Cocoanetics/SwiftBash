import Foundation

// AwkParserState extension carrying primary/field-index/print parsing.
extension AwkParserState {

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    mutating func parsePrimary(inPrint: Bool) throws -> AwkExpr {
        let tok = peek()
        switch tok.kind {
        case .number(let num):
            advance(); return .number(num)
        case .string(let str):
            advance(); return .string(str)
        case .regex(let pat):
            advance(); return .regex(pat)
        case .dollar:
            advance()
            let idx = try parseFieldIndex()
            return .field(idx)
        case .lparen:
            advance()
            let first = try parseExpression(inPrint: inPrint)
            if check(.comma) {
                var elems: [AwkExpr] = [first]
                while check(.comma) {
                    advance()
                    elems.append(try parseExpression(inPrint: inPrint))
                }
                _ = try expect(.rparen, "expected ')'")
                return .tuple(elems)
            }
            _ = try expect(.rparen, "expected ')'")
            return first
        case .kGetline:
            advance()
            var varName: String?
            if case .ident(let name) = peek().kind { advance(); varName = name }
            var file: AwkExpr?
            if check(.lt) {
                advance()
                file = try parsePrimary(inPrint: inPrint)
            }
            return .getline(variable: varName, file: file, command: nil)
        case .ident(let name):
            advance()
            if check(.lparen) {
                advance()
                skipNewlines()
                var args: [AwkExpr] = []
                if !check(.rparen) {
                    args.append(try parseExpression(inPrint: false))
                    while check(.comma) {
                        advance()
                        skipNewlines()
                        args.append(try parseExpression(inPrint: false))
                    }
                }
                skipNewlines()
                _ = try expect(.rparen, "expected ')'")
                return .call(name: name, args: args)
            }
            if check(.lbracket) {
                advance()
                var keys: [AwkExpr] = [try parseExpression(inPrint: inPrint)]
                while check(.comma) {
                    advance()
                    keys.append(try parseExpression(inPrint: inPrint))
                }
                _ = try expect(.rbracket, "expected ']'")
                let key = combineKeys(keys)
                return .arrayAccess(name: name, key: key)
            }
            return .variable(name)
        default:
            throw AwkParseError("unexpected token \(tok.kind) at line \(tok.line):\(tok.column)")
        }
    }

    /// Parse a field-index expression that doesn't bind postfix
    /// `++`/`--` to the expression — those apply to `$index`, not
    /// to `index`. Otherwise `$i++` would parse as `$(i++)`.
    mutating func parseFieldIndex() throws -> AwkExpr {
        if check(.increment) {
            advance()
            let operand = try parseFieldIndex()
            if let lvalue = try? lvalueFromExpr(operand) { return .preIncrement(lvalue) }
            return .unary(.pos, .unary(.pos, operand))
        }
        if check(.decrement) {
            advance()
            let operand = try parseFieldIndex()
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
            let operand = try parseFieldIndex()
            return .unary(unaryOp, operand)
        }
        // Power on field-index has the same shape as power
        // elsewhere, but the base must not consume postfix ops.
        var lhs = try parseFieldIndexPrimary()
        if check(.caret) {
            advance()
            let rhs = try parseFieldIndex()
            lhs = .binary(.pow, lhs, rhs)
        }
        return lhs
    }

    // swiftlint:disable:next cyclomatic_complexity
    mutating func parseFieldIndexPrimary() throws -> AwkExpr {
        let tok = peek()
        switch tok.kind {
        case .number(let num): advance(); return .number(num)
        case .string(let str): advance(); return .string(str)
        case .dollar:
            advance()
            let idx = try parseFieldIndex()
            return .field(idx)
        case .lparen:
            advance()
            let expr = try parseExpression(inPrint: false)
            _ = try expect(.rparen, "expected ')'")
            return expr
        case .ident(let name):
            advance()
            if check(.lparen) {
                advance()
                var args: [AwkExpr] = []
                if !check(.rparen) {
                    args.append(try parseExpression(inPrint: false))
                    while check(.comma) {
                        advance()
                        args.append(try parseExpression(inPrint: false))
                    }
                }
                _ = try expect(.rparen, "expected ')'")
                return .call(name: name, args: args)
            }
            if check(.lbracket) {
                advance()
                var keys: [AwkExpr] = [try parseExpression(inPrint: false)]
                while check(.comma) {
                    advance()
                    keys.append(try parseExpression(inPrint: false))
                }
                _ = try expect(.rbracket, "expected ']'")
                let key = combineKeys(keys)
                return .arrayAccess(name: name, key: key)
            }
            return .variable(name)
        default:
            throw AwkParseError("unexpected token \(tok.kind) in field index")
        }
    }

    func combineKeys(_ keys: [AwkExpr]) -> AwkExpr {
        if keys.count == 1 { return keys[0] }
        // Concatenate with SUBSEP between each pair.
        var key = keys[0]
        for idx in 1..<keys.count {
            key = .binary(.concat,
                          .binary(.concat, key, .variable("SUBSEP")),
                          keys[idx])
        }
        return key
    }

    // MARK: print-context helpers

    mutating func parsePrintArg() throws -> AwkExpr {
        // Look ahead for a `?` before any statement terminator —
        // tells us whether `>` should parse as comparison (inside
        // ternary) or redirection.
        let hasTernary = lookAheadForTernary()
        if hasTernary {
            return try parsePrintAssignment(allowGt: true)
        }
        return try parsePrintAssignment(allowGt: false)
    }

    mutating func parsePrintAssignment(allowGt: Bool) throws -> AwkExpr {
        let lhs: AwkExpr
        if allowGt {
            lhs = try parseTernary(inPrint: false)
        } else {
            lhs = try parseOr(inPrint: true)
        }
        if let assignOp = currentAssignOp() {
            advance()
            let rhs = try parsePrintAssignment(allowGt: allowGt)
            let target = try lvalueFromExpr(lhs)
            return .assignment(assignOp, target: target, value: rhs)
        }
        return lhs
    }

    func lookAheadForTernary() -> Bool {
        var depth = 0
        var idx = pos
        while idx < tokens.count {
            let tok = tokens[idx]
            if depth == 0 {
                switch tok.kind {
                case .question: return true
                case .newline, .semicolon, .rbrace, .comma, .pipe: return false
                default: break
                }
            }
            switch tok.kind {
            case .lparen: depth += 1
            case .rparen: depth -= 1
            default: break
            }
            idx += 1
        }
        return false
    }
}
