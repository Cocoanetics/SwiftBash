import Foundation

/// AST produced by ``ArithParser`` from a tokenised arithmetic expression.
public indirect enum ArithExpr: Hashable, Sendable {
    case int(Int64)
    case variable(String)

    case unary(UnaryOp, ArithExpr)

    /// Pre-/post-fix inc/dec applied to a bare variable reference.
    case prefix(IncDec, name: String)
    case postfix(IncDec, name: String)

    case binary(BinaryOp, ArithExpr, ArithExpr)

    /// `cond ? then : else`
    case ternary(ArithExpr, ArithExpr, ArithExpr)

    /// `name op= rhs` (including plain `=`)
    case assign(name: String, op: AssignOp, rhs: ArithExpr)

    /// Comma-separated sequence: evaluate each, return the last.
    case sequence([ArithExpr])

    public enum UnaryOp: Hashable, Sendable {
        case plus, minus       // +, -
        case logicalNot        // !
        case bitwiseNot        // ~
    }

    public enum IncDec: Hashable, Sendable { case inc, dec }

    public enum BinaryOp: Hashable, Sendable {
        case add, sub, mul, div, mod, pow
        case shl, shr
        case bitAnd, bitOr, bitXor
        case lt, gt, le, ge, eq, neq
        case logicalAnd, logicalOr
    }

    public enum AssignOp: Hashable, Sendable {
        case set
        case addSet, subSet, mulSet, divSet, modSet, powSet
        case shlSet, shrSet
        case andSet, orSet, xorSet

        /// For compound assignments, the pure binary op that pairs with the
        /// current value; `nil` for plain `=`.
        public var pairedBinary: ArithExpr.BinaryOp? {
            switch self {
            case .set: return nil
            case .addSet: return .add
            case .subSet: return .sub
            case .mulSet: return .mul
            case .divSet: return .div
            case .modSet: return .mod
            case .powSet: return .pow
            case .shlSet: return .shl
            case .shrSet: return .shr
            case .andSet: return .bitAnd
            case .orSet:  return .bitOr
            case .xorSet: return .bitXor
            }
        }
    }
}
