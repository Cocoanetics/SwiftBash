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
        case .unexpectedCharacter(let char, let pos):
            return "unexpected character '\(char)' at position \(pos)"
        case .invalidNumber(let text):
            return "invalid number literal: '\(text)'"
        case .invalidBase(let base):
            return "invalid base: \(base) (must be 2..64)"
        case .digitOutOfRange(let digit, let base):
            return "digit '\(digit)' out of range for base \(base)"
        case .unexpectedToken(let text):
            return "unexpected token: '\(text)'"
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
        case .negativeExponent(let exponent):
            return "exponent must be non-negative (got \(exponent))"
        case .recursionLimit:
            return "variable recursion limit exceeded"
        }
    }
}
