import Foundation

/// Recursive-descent parser for AWK. Mirrors the precedence rules
/// laid out in just-bash's `parser2.ts`: assignment > ternary > pipe-
/// getline > or > and > in > concat > match > comparison > add/sub >
/// mul/div > unary > power > postfix > primary.
///
/// Print/printf use a sibling stack of "print-context" parsers so that
/// `>` and `>>` are redirection at top level but stay as comparison
/// inside `?:`. We mark a print arg's parsing context with the
/// `inPrint` flag throughout.
public struct AwkParser {

    public static func parse(_ source: String) throws -> AwkProgram {
        var lexer = AwkLexer(source)
        let toks = try lexer.tokenize()
        var p = Parser(tokens: toks)
        return try p.parseProgram()
    }

    fileprivate struct Parser {
        var tokens: [AwkToken]
        var pos = 0

        // MARK: token helpers
        func peek(_ offset: Int = 0) -> AwkToken {
            let i = pos + offset
            return i < tokens.count ? tokens[i] : tokens[tokens.count - 1]
        }
        @discardableResult mutating func advance() -> AwkToken {
            defer { pos += 1 }
            return tokens[pos]
        }
        func check(_ kind: AwkTokenKind) -> Bool { peek().kind == kind }
        mutating func match(_ kinds: AwkTokenKind...) -> Bool {
            for k in kinds where check(k) { return true }
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
            let t = peek()
            guard case .ident(let s) = t.kind else {
                throw AwkParseError("expected identifier at line \(t.line):\(t.column)")
            }
            advance()
            return s
        }

        mutating func parseRule() throws -> AwkRule {
            var pattern: AwkPattern? = nil
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

        func lvalueFromExpr(_ e: AwkExpr) throws -> AwkLValue {
            switch e {
            case .variable(let n): return .variable(n)
            case .field(let idx): return .field(idx)
            case .arrayAccess(let n, let k): return .arrayAccess(name: n, key: k)
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
            var alt: AwkStmt? = nil
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
            var initE: AwkExpr? = nil
            if !check(.semicolon) {
                initE = try parseExpression(inPrint: false)
            }
            _ = try expect(.semicolon, "expected ';' after for-init")
            var condE: AwkExpr? = nil
            if !check(.semicolon) {
                condE = try parseExpression(inPrint: false)
            }
            _ = try expect(.semicolon, "expected ';' after for-cond")
            var updE: AwkExpr? = nil
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

        // MARK: expression — precedence climbing

        mutating func parseExpression(inPrint: Bool) throws -> AwkExpr {
            try parseAssignment(inPrint: inPrint)
        }

        mutating func parseAssignment(inPrint: Bool) throws -> AwkExpr {
            let lhs = try parseTernary(inPrint: inPrint)
            if let op = currentAssignOp() {
                advance()
                let rhs = try parseAssignment(inPrint: inPrint)
                let target = try lvalueFromExpr(lhs)
                return .assignment(op, target: target, value: rhs)
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
                var v: String? = nil
                if case .ident(let n) = peek().kind {
                    advance()
                    v = n
                }
                return .getline(variable: v, file: nil, command: left)
            }
            return left
        }

        mutating func parseOr(inPrint: Bool) throws -> AwkExpr {
            var l = try parseAnd(inPrint: inPrint)
            while check(.or) {
                advance()
                let r = try parseAnd(inPrint: inPrint)
                l = .binary(.or, l, r)
            }
            return l
        }

        mutating func parseAnd(inPrint: Bool) throws -> AwkExpr {
            var l = try parseIn(inPrint: inPrint)
            while check(.and) {
                advance()
                let r = try parseIn(inPrint: inPrint)
                l = .binary(.and, l, r)
            }
            return l
        }

        mutating func parseLogicalOrRest(left: AwkExpr) throws -> AwkExpr {
            var l = left
            while check(.and) {
                advance()
                let r = try parseIn(inPrint: false)
                l = .binary(.and, l, r)
            }
            while check(.or) {
                advance()
                let r = try parseAnd(inPrint: false)
                l = .binary(.or, l, r)
            }
            return l
        }

        mutating func parseIn(inPrint: Bool) throws -> AwkExpr {
            let l = try parseConcatenation(inPrint: inPrint)
            if check(.kIn) {
                advance()
                let arr = try identName()
                return .inExpr(key: l, array: arr)
            }
            return l
        }

        mutating func parseConcatenation(inPrint: Bool) throws -> AwkExpr {
            var l = try parseMatch(inPrint: inPrint)
            while canStartExpression() && !isConcatTerminator(inPrint: inPrint) {
                let r = try parseMatch(inPrint: inPrint)
                l = .binary(.concat, l, r)
            }
            return l
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
            var l = try parseComparison(inPrint: inPrint)
            while match(.match, .notMatch) {
                let op: AwkBinaryOp = check(.match) ? .match : .notMatch
                advance()
                let r = try parseComparison(inPrint: inPrint)
                l = .binary(op, l, r)
            }
            return l
        }

        mutating func parseComparison(inPrint: Bool) throws -> AwkExpr {
            var l = try parseAddSub()
            while true {
                let op: AwkBinaryOp?
                switch peek().kind {
                case .lt: op = .lt
                case .le: op = .le
                case .gt where !inPrint: op = .gt
                case .ge: op = .ge
                case .eq: op = .eq
                case .ne: op = .ne
                default: op = nil
                }
                guard let op else { break }
                advance()
                let r = try parseAddSub()
                l = .binary(op, l, r)
            }
            return l
        }

        mutating func parseAddSub() throws -> AwkExpr {
            var l = try parseMulDiv()
            while match(.plus, .minus) {
                let op: AwkBinaryOp = check(.plus) ? .add : .sub
                advance()
                let r = try parseMulDiv()
                l = .binary(op, l, r)
            }
            return l
        }

        mutating func parseMulDiv() throws -> AwkExpr {
            var l = try parseUnary()
            while match(.star, .slash, .percent) {
                let op: AwkBinaryOp
                switch peek().kind {
                case .star: op = .mul
                case .slash: op = .div
                default: op = .mod
                }
                advance()
                let r = try parseUnary()
                l = .binary(op, l, r)
            }
            return l
        }

        mutating func parseUnary() throws -> AwkExpr {
            if check(.increment) {
                advance()
                let op = try parseUnary()
                if let lv = try? lvalueFromExpr(op) { return .preIncrement(lv) }
                return .unary(.pos, .unary(.pos, op))
            }
            if check(.decrement) {
                advance()
                let op = try parseUnary()
                if let lv = try? lvalueFromExpr(op) { return .preDecrement(lv) }
                return .unary(.neg, .unary(.neg, op))
            }
            if match(.not, .minus, .plus) {
                let op: AwkUnaryOp
                switch peek().kind {
                case .not: op = .not
                case .minus: op = .neg
                default: op = .pos
                }
                advance()
                let operand = try parseUnary()
                return .unary(op, operand)
            }
            return try parsePower()
        }

        mutating func parsePower() throws -> AwkExpr {
            let l = try parsePostfix()
            if check(.caret) {
                advance()
                let r = try parsePower()    // right-associative
                return .binary(.pow, l, r)
            }
            return l
        }

        mutating func parsePostfix() throws -> AwkExpr {
            let e = try parsePrimary(inPrint: false)
            if check(.increment) {
                advance()
                let lv = try lvalueFromExpr(e)
                return .postIncrement(lv)
            }
            if check(.decrement) {
                advance()
                let lv = try lvalueFromExpr(e)
                return .postDecrement(lv)
            }
            return e
        }

        mutating func parsePrimary(inPrint: Bool) throws -> AwkExpr {
            let t = peek()
            switch t.kind {
            case .number(let n):
                advance(); return .number(n)
            case .string(let s):
                advance(); return .string(s)
            case .regex(let p):
                advance(); return .regex(p)
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
                var v: String? = nil
                if case .ident(let n) = peek().kind { advance(); v = n }
                var file: AwkExpr? = nil
                if check(.lt) {
                    advance()
                    file = try parsePrimary(inPrint: inPrint)
                }
                return .getline(variable: v, file: file, command: nil)
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
                throw AwkParseError("unexpected token \(t.kind) at line \(t.line):\(t.column)")
            }
        }

        /// Parse a field-index expression that doesn't bind postfix
        /// `++`/`--` to the expression — those apply to `$index`, not
        /// to `index`. Otherwise `$i++` would parse as `$(i++)`.
        mutating func parseFieldIndex() throws -> AwkExpr {
            if check(.increment) {
                advance()
                let op = try parseFieldIndex()
                if let lv = try? lvalueFromExpr(op) { return .preIncrement(lv) }
                return .unary(.pos, .unary(.pos, op))
            }
            if check(.decrement) {
                advance()
                let op = try parseFieldIndex()
                if let lv = try? lvalueFromExpr(op) { return .preDecrement(lv) }
                return .unary(.neg, .unary(.neg, op))
            }
            if match(.not, .minus, .plus) {
                let op: AwkUnaryOp
                switch peek().kind {
                case .not: op = .not
                case .minus: op = .neg
                default: op = .pos
                }
                advance()
                let operand = try parseFieldIndex()
                return .unary(op, operand)
            }
            // Power on field-index has the same shape as power
            // elsewhere, but the base must not consume postfix ops.
            var l = try parseFieldIndexPrimary()
            if check(.caret) {
                advance()
                let r = try parseFieldIndex()
                l = .binary(.pow, l, r)
            }
            return l
        }

        mutating func parseFieldIndexPrimary() throws -> AwkExpr {
            let t = peek()
            switch t.kind {
            case .number(let n): advance(); return .number(n)
            case .string(let s): advance(); return .string(s)
            case .dollar:
                advance()
                let idx = try parseFieldIndex()
                return .field(idx)
            case .lparen:
                advance()
                let e = try parseExpression(inPrint: false)
                _ = try expect(.rparen, "expected ')'")
                return e
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
                throw AwkParseError("unexpected token \(t.kind) in field index")
            }
        }

        func combineKeys(_ keys: [AwkExpr]) -> AwkExpr {
            if keys.count == 1 { return keys[0] }
            // Concatenate with SUBSEP between each pair.
            var k = keys[0]
            for i in 1..<keys.count {
                k = .binary(.concat,
                            .binary(.concat, k, .variable("SUBSEP")),
                            keys[i])
            }
            return k
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
            if let op = currentAssignOp() {
                advance()
                let rhs = try parsePrintAssignment(allowGt: allowGt)
                let target = try lvalueFromExpr(lhs)
                return .assignment(op, target: target, value: rhs)
            }
            return lhs
        }

        func lookAheadForTernary() -> Bool {
            var depth = 0
            var i = pos
            while i < tokens.count {
                let t = tokens[i]
                if depth == 0 {
                    switch t.kind {
                    case .question: return true
                    case .newline, .semicolon, .rbrace, .comma, .pipe: return false
                    default: break
                    }
                }
                switch t.kind {
                case .lparen: depth += 1
                case .rparen: depth -= 1
                default: break
                }
                i += 1
            }
            return false
        }
    }
}
