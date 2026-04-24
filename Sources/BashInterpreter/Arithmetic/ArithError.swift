import Foundation

/// Errors raised while lexing, parsing, or evaluating a bash arithmetic
/// expression (`((…))` / `$((…))`).
public enum ArithError: Error, Equatable, Sendable, CustomStringConvertible {
    case unexpectedCharacter(Character, position: Int)
    case invalidNumber(String)
    case invalidBase(Int)
    case digitOutOfRange(digit: Character, forBase: Int)
    case unexpectedToken(String)
    case unexpectedEnd
    case expectedColon
    case invalidAssignmentTarget
    case divisionByZero
    case moduloByZero
    case negativeExponent(Int64)
    case recursionLimit

    public var description: String {
        switch self {
        case .unexpectedCharacter(let c, let pos):
            return "unexpected character '\(c)' at position \(pos)"
        case .invalidNumber(let s):
            return "invalid number literal: '\(s)'"
        case .invalidBase(let b):
            return "invalid base: \(b) (must be 2..64)"
        case .digitOutOfRange(let d, let b):
            return "digit '\(d)' out of range for base \(b)"
        case .unexpectedToken(let s):
            return "unexpected token: '\(s)'"
        case .unexpectedEnd:
            return "unexpected end of expression"
        case .expectedColon:
            return "expected ':' in ternary expression"
        case .invalidAssignmentTarget:
            return "assignment target must be a variable name"
        case .divisionByZero:
            return "division by zero"
        case .moduloByZero:
            return "modulo by zero"
        case .negativeExponent(let e):
            return "exponent must be non-negative (got \(e))"
        case .recursionLimit:
            return "variable recursion limit exceeded"
        }
    }
}
