import Foundation

/// A Pratt (top-down operator precedence) parser for bash arithmetic.
///
/// The precedence table matches `bash(1)` — from tightest to loosest:
/// postfix `++` `--` ▸ prefix `++` `--` ▸ unary `+ - ! ~` ▸ `**` ▸ `* / %` ▸
/// `+ -` ▸ `<< >>` ▸ `< > <= >=` ▸ `== !=` ▸ `&` ▸ `^` ▸ `|` ▸ `&&` ▸ `||` ▸
/// `? :` ▸ `= *= /= %= += -= <<= >>= &= ^= |= **=` ▸ `,`.
///
/// `**`, `? :`, assignments, and the sequence operator `,` are
/// right-associative (achieved by using `rbp = lbp - 1` for their led
/// recursion). Everything else is left-associative.
///
/// Unary `-` / `+` / `!` / `~` bind at a level between additive and
/// exponentiation — matching bash's behaviour where `-2 ** 2` is `-(2**2)`
/// = -4 but `-2 * 3` is `(-2) * 3` = -6.
public struct ArithParser {

    public init() {}

    public func parse(_ source: String) throws -> ArithExpr {
        let tokens = try ArithLexer.tokenize(source)
        var state = State(tokens: tokens)
        let expr = try parseExpression(minBP: 0, state: &state)
        guard state.peek() == .eof else {
            throw ArithError.unexpectedToken(state.peek().description)
        }
        return expr
    }

    /// Parse starting from an already-tokenised sequence. Useful for tests.
    public func parse(tokens: [ArithToken]) throws -> ArithExpr {
        var state = State(tokens: tokens)
        let expr = try parseExpression(minBP: 0, state: &state)
        guard state.peek() == .eof else {
            throw ArithError.unexpectedToken(state.peek().description)
        }
        return expr
    }

    // MARK: State

    private struct State {
        let tokens: [ArithToken]
        var i: Int = 0

        func peek(_ offset: Int = 0) -> ArithToken {
            let j = i + offset
            return j < tokens.count ? tokens[j] : .eof
        }

        @discardableResult
        mutating func advance() -> ArithToken {
            let t = peek()
            if i < tokens.count { i += 1 }
            return t
        }
    }

    // MARK: Precedence

    /// Precedence "levels" — higher = binds tighter.
    /// The lbp/rbp split encodes associativity: `rbp == lbp` is
    /// left-associative; `rbp == lbp - 1` is right-associative.
    private static let COMMA   = (lbp: 10, rbp: 10)  // left-assoc flattens cleanly
    private static let ASSIGN  = (lbp: 20, rbp: 19)  // right-assoc
    private static let TERNARY = (lbp: 30, rbp: 29)  // right-assoc
    private static let LOR     = (lbp: 40, rbp: 40)
    private static let LAND    = (lbp: 50, rbp: 50)
    private static let BOR     = (lbp: 60, rbp: 60)
    private static let BXOR    = (lbp: 70, rbp: 70)
    private static let BAND    = (lbp: 80, rbp: 80)
    private static let EQUAL   = (lbp: 90, rbp: 90)
    private static let COMPARE = (lbp: 100, rbp: 100)
    private static let SHIFT   = (lbp: 110, rbp: 110)
    private static let ADD     = (lbp: 120, rbp: 120)
    private static let MUL     = (lbp: 130, rbp: 130)
    private static let UNARY   = 135
    private static let POW     = (lbp: 140, rbp: 139) // right-assoc
    private static let POSTFIX = 150

    private func infixBP(_ tok: ArithToken) -> (lbp: Int, rbp: Int)? {
        switch tok {
        case .comma:               return Self.COMMA
        case .assign, .plusAssign, .minusAssign, .starAssign, .slashAssign,
             .percentAssign, .shiftLeftAssign, .shiftRightAssign,
             .ampAssign, .caretAssign, .barAssign, .starStarAssign:
            return Self.ASSIGN
        case .question:            return Self.TERNARY
        case .barBar:              return Self.LOR
        case .ampAmp:              return Self.LAND
        case .bar:                 return Self.BOR
        case .caret:               return Self.BXOR
        case .amp:                 return Self.BAND
        case .eq, .neq:            return Self.EQUAL
        case .lt, .gt, .le, .ge:   return Self.COMPARE
        case .shiftLeft, .shiftRight:
            return Self.SHIFT
        case .plus, .minus:        return Self.ADD
        case .star, .slash, .percent:
            return Self.MUL
        case .starStar:            return Self.POW
        case .plusPlus, .minusMinus:
            // Postfix — handled via a special branch, but must win against
            // everything else to be consumed eagerly.
            return (lbp: Self.POSTFIX, rbp: Self.POSTFIX)
        default:                   return nil
        }
    }

    // MARK: Core loop

    private func parseExpression(minBP: Int, state: inout State) throws -> ArithExpr {
        var left = try parseNud(state: &state)

        while true {
            let tok = state.peek()
            guard let bp = infixBP(tok), bp.lbp > minBP else { break }

            // Postfix `++` / `--` — consume and wrap; don't recurse.
            if tok == .plusPlus || tok == .minusMinus {
                state.advance()
                let op: ArithExpr.IncDec = (tok == .plusPlus) ? .inc : .dec
                switch left {
                case .variable(let name):
                    left = .postfix(op, name: name)
                case .arrayIndex(let name, let index):
                    left = .postfixIndexed(op, name: name, index: index)
                default:
                    throw ArithError.invalidAssignmentTarget
                }
                continue
            }

            // Ternary `? then : else`.
            if tok == .question {
                state.advance()
                let thenExpr = try parseExpression(minBP: 0, state: &state)
                guard state.peek() == .colon else {
                    throw ArithError.expectedColon
                }
                state.advance()
                let elseExpr = try parseExpression(minBP: bp.rbp, state: &state)
                left = .ternary(left, thenExpr, elseExpr)
                continue
            }

            // Assignment (single or compound) — LHS may be a bare
            // variable or an indexed `arr[i]`.
            if let assignOp = assignmentOp(for: tok) {
                state.advance()
                let right = try parseExpression(minBP: bp.rbp, state: &state)
                switch left {
                case .variable(let name):
                    left = .assign(name: name, op: assignOp, rhs: right)
                case .arrayIndex(let name, let index):
                    left = .assignIndex(name: name, index: index,
                                        op: assignOp, rhs: right)
                default:
                    throw ArithError.invalidAssignmentTarget
                }
                continue
            }

            // Comma / sequence.
            if tok == .comma {
                state.advance()
                let right = try parseExpression(minBP: bp.rbp, state: &state)
                if case .sequence(var parts) = left {
                    parts.append(right)
                    left = .sequence(parts)
                } else {
                    left = .sequence([left, right])
                }
                continue
            }

            // Regular infix binary operator.
            state.advance()
            let right = try parseExpression(minBP: bp.rbp, state: &state)
            left = .binary(binaryOp(for: tok)!, left, right)
        }

        return left
    }

    private func parseNud(state: inout State) throws -> ArithExpr {
        let tok = state.advance()
        switch tok {
        case .int(let n):
            return .int(n)
        case .ident(let name):
            // `name[index]` — read array element.
            if state.peek() == .lBracket {
                state.advance()
                let index = try parseExpression(minBP: 0, state: &state)
                guard state.peek() == .rBracket else {
                    throw ArithError.unexpectedToken(state.peek().description)
                }
                state.advance()
                return .arrayIndex(name: name, index: index)
            }
            return .variable(name)
        case .lParen:
            let inner = try parseExpression(minBP: 0, state: &state)
            guard state.peek() == .rParen else {
                throw ArithError.unexpectedToken(state.peek().description)
            }
            state.advance()
            return inner
        case .plus:
            let operand = try parseExpression(minBP: Self.UNARY, state: &state)
            return .unary(.plus, operand)
        case .minus:
            let operand = try parseExpression(minBP: Self.UNARY, state: &state)
            return .unary(.minus, operand)
        case .bang:
            let operand = try parseExpression(minBP: Self.UNARY, state: &state)
            return .unary(.logicalNot, operand)
        case .tilde:
            let operand = try parseExpression(minBP: Self.UNARY, state: &state)
            return .unary(.bitwiseNot, operand)
        case .plusPlus:
            // Prefix `++x` or `++arr[i]` — operand must be an l-value.
            let operand = try parseExpression(minBP: Self.UNARY, state: &state)
            switch operand {
            case .variable(let name):
                return .prefix(.inc, name: name)
            case .arrayIndex(let name, let index):
                return .prefixIndexed(.inc, name: name, index: index)
            default:
                throw ArithError.invalidAssignmentTarget
            }
        case .minusMinus:
            let operand = try parseExpression(minBP: Self.UNARY, state: &state)
            switch operand {
            case .variable(let name):
                return .prefix(.dec, name: name)
            case .arrayIndex(let name, let index):
                return .prefixIndexed(.dec, name: name, index: index)
            default:
                throw ArithError.invalidAssignmentTarget
            }
        case .eof:
            throw ArithError.unexpectedEnd
        default:
            throw ArithError.unexpectedToken(tok.description)
        }
    }

    // MARK: Dispatch tables

    private func binaryOp(for tok: ArithToken) -> ArithExpr.BinaryOp? {
        switch tok {
        case .plus: return .add
        case .minus: return .sub
        case .star: return .mul
        case .slash: return .div
        case .percent: return .mod
        case .starStar: return .pow
        case .shiftLeft: return .shl
        case .shiftRight: return .shr
        case .amp: return .bitAnd
        case .bar: return .bitOr
        case .caret: return .bitXor
        case .lt: return .lt
        case .gt: return .gt
        case .le: return .le
        case .ge: return .ge
        case .eq: return .eq
        case .neq: return .neq
        case .ampAmp: return .logicalAnd
        case .barBar: return .logicalOr
        default: return nil
        }
    }

    private func assignmentOp(for tok: ArithToken) -> ArithExpr.AssignOp? {
        switch tok {
        case .assign: return .set
        case .plusAssign: return .addSet
        case .minusAssign: return .subSet
        case .starAssign: return .mulSet
        case .slashAssign: return .divSet
        case .percentAssign: return .modSet
        case .starStarAssign: return .powSet
        case .shiftLeftAssign: return .shlSet
        case .shiftRightAssign: return .shrSet
        case .ampAssign:   return .andSet
        case .caretAssign: return .xorSet
        case .barAssign:   return .orSet
        default: return nil
        }
    }
}
