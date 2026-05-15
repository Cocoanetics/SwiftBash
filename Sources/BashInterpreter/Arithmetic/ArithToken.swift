import Foundation

/// A token produced by ``ArithLexer`` for a bash arithmetic expression.
public enum ArithToken: Hashable, Sendable {
    // Operands
    case int(Int64)
    case ident(String)

    // Arithmetic
    case plus, minus, star, slash, percent, starStar

    // Increment / decrement
    case plusPlus, minusMinus

    // Comparison — two-letter spellings mirror operator source forms.
    // swiftlint:disable:next identifier_name
    case lt, gt, le, ge, eq, neq

    // Logical
    case ampAmp, barBar, bang

    // Bitwise
    case amp, bar, caret, tilde, shiftLeft, shiftRight

    // Ternary
    case question, colon

    // Assignments
    case assign                         // =
    case plusAssign, minusAssign        // += -=
    case starAssign, slashAssign        // *= /=
    case percentAssign, starStarAssign  // %= **=
    case shiftLeftAssign, shiftRightAssign // <<= >>=
    case ampAssign, caretAssign, barAssign // &= ^= |=

    // Grouping / separator
    case lParen, rParen, comma

    // Array indexing — `arr[expr]` inside `((…))`.
    case lBracket, rBracket

    case eof

    /// A human-readable rendering used in error messages.
    public var description: String {
        switch self {
        case .int(let num): return "\(num)"
        case .ident(let name): return name
        case .plus: return "+"
        case .minus: return "-"
        case .star: return "*"
        case .slash: return "/"
        case .percent: return "%"
        case .starStar: return "**"
        case .plusPlus: return "++"
        case .minusMinus: return "--"
        case .lt: return "<"
        case .gt: return ">"
        case .le: return "<="
        case .ge: return ">="
        case .eq: return "=="
        case .neq: return "!="
        case .ampAmp: return "&&"
        case .barBar: return "||"
        case .bang: return "!"
        case .amp: return "&"
        case .bar: return "|"
        case .caret: return "^"
        case .tilde: return "~"
        case .shiftLeft: return "<<"
        case .shiftRight: return ">>"
        case .question: return "?"
        case .colon: return ":"
        case .assign: return "="
        case .plusAssign: return "+="
        case .minusAssign: return "-="
        case .starAssign: return "*="
        case .slashAssign: return "/="
        case .percentAssign: return "%="
        case .starStarAssign: return "**="
        case .shiftLeftAssign: return "<<="
        case .shiftRightAssign: return ">>="
        case .ampAssign: return "&="
        case .caretAssign: return "^="
        case .barAssign: return "|="
        case .lParen: return "("
        case .rParen: return ")"
        case .comma: return ","
        case .lBracket: return "["
        case .rBracket: return "]"
        case .eof: return "<eof>"
        }
    }
}
