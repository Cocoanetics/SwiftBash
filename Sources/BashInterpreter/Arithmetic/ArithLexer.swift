import Foundation

/// Lexes a bash arithmetic expression into a stream of ``ArithToken``s.
///
/// Supports integer literals in several bases:
/// - Decimal: `123`
/// - Hex:     `0x7f`, `0XFF`
/// - Octal:   `0777` (leading zero)
/// - Base-N:  `N#digits` where N is 2..64. Digits use `0-9a-zA-Z@_` to
///   cover bases up to 64 (the bash extension).
///
/// Also recognises every arithmetic, comparison, bitwise, logical,
/// assignment, inc/dec and grouping operator bash accepts in `((…))`.
public enum ArithLexer {

    /// Tokenise `source` into an array ending with `.eof`.
    public static func tokenize(_ source: String) throws -> [ArithToken] {
        var lexer = Lexer(chars: Array(source))
        var out: [ArithToken] = []
        while true {
            lexer.skipBlanks()
            guard let tok = try lexer.nextToken() else {
                out.append(.eof)
                return out
            }
            out.append(tok)
        }
    }

    // MARK: Implementation

    struct Lexer {
        let chars: [Character]
        var index: Int = 0

        mutating func skipBlanks() {
            while index < chars.count, chars[index].isWhitespace {
                index += 1
            }
        }

        mutating func peek(_ offset: Int = 0) -> Character? {
            let idx = index + offset
            return (0 <= idx && idx < chars.count) ? chars[idx] : nil
        }

        @discardableResult
        mutating func advance() -> Character? {
            guard index < chars.count else { return nil }
            let char = chars[index]
            index += 1
            return char
        }

        mutating func nextToken() throws -> ArithToken? {
            guard let char = peek() else { return nil }

            // Identifiers and `$var` references
            if char == "$" {
                advance()
                guard let next = peek() else {
                    throw ArithError.unexpectedCharacter(char, position: index - 1)
                }
                // `$name` — read identifier.
                if next.isLetter || next == "_" {
                    return .ident(try readIdentifier())
                }
                // `$1`, `$10`, … — positional parameter ref. We emit
                // an ident token whose name is the digit string; the
                // `get` closure looks it up in `positionalParameters`.
                if next.isNumber {
                    var digits = ""
                    while let digit = peek(), digit.isNumber {
                        digits.append(digit); advance()
                    }
                    return .ident(digits)
                }
                throw ArithError.unexpectedCharacter(char, position: index - 1)
            }
            if char.isLetter || char == "_" {
                return .ident(try readIdentifier())
            }

            // Numeric literals (or base#… which starts as a run of digits).
            if char.isNumber {
                return try readNumber()
            }

            // Operators / punctuation
            return try readOperator()
        }

        // MARK: Identifier

        mutating func readIdentifier() throws -> String {
            var buf = ""
            while let char = peek(), char.isLetter || char.isNumber || char == "_" {
                buf.append(char)
                advance()
            }
            if buf.isEmpty {
                throw ArithError.unexpectedCharacter(peek() ?? " ", position: index)
            }
            return buf
        }

        // MARK: Numbers

        /// Reads an integer literal starting at `peek()` which is a digit.
        /// Handles decimal, `0x…` / `0X…` hex, leading-zero octal, and
        /// `base#digits` forms.
        mutating func readNumber() throws -> ArithToken {
            let start = index
            // Consume the digit run.
            var digits = ""
            while let char = peek(), char.isNumber {
                digits.append(char); advance()
            }

            // base#digits form
            if peek() == "#" {
                guard let base = Int(digits), 2...64 ~= base else {
                    throw ArithError.invalidBase(Int(digits) ?? 0)
                }
                advance() // consume '#'
                return try .int(readBaseDigits(base: base))
            }

            // 0x / 0X — hex
            if digits == "0", let char = peek(), char == "x" || char == "X" {
                advance() // consume x/X
                return try .int(readBaseDigits(base: 16))
            }

            // 0 with following digits — octal
            if digits.hasPrefix("0"), digits.count > 1,
               digits.allSatisfy({ "01234567".contains($0) }) {
                guard let num = Int64(digits, radix: 8) else {
                    throw ArithError.invalidNumber(digits)
                }
                return .int(num)
            }
            if digits.hasPrefix("0"), digits.count > 1 {
                // Has a non-octal digit like '8' or '9' → error.
                throw ArithError.digitOutOfRange(digit: digits.dropFirst()
                    .first(where: { !"01234567".contains($0) })!, forBase: 8)
            }

            // Plain decimal
            guard let num = Int64(digits) else {
                throw ArithError.invalidNumber(digits)
            }
            _ = start
            return .int(num)
        }

        /// Reads a run of base-N digit characters and returns the value.
        /// Valid digit chars follow bash's table:
        ///   0-9  → 0-9
        ///   a-z  → 10-35
        ///   A-Z  → 36-61
        ///   @    → 62
        ///   _    → 63
        /// For bases ≤ 36 we accept the case-insensitive subset.
        mutating func readBaseDigits(base: Int) throws -> Int64 {
            var result: Int64 = 0
            var consumed = false
            while let char = peek() {
                guard let digitVal = Self.baseDigitValue(char, base: base) else {
                    if !consumed {
                        throw ArithError.digitOutOfRange(digit: char, forBase: base)
                    }
                    break
                }
                result = result &* Int64(base) &+ Int64(digitVal)
                advance()
                consumed = true
            }
            if !consumed { throw ArithError.unexpectedEnd }
            return result
        }

        static func baseDigitValue(_ char: Character, base: Int) -> Int? {
            let value: Int
            switch char {
            case "0"..."9":
                value = Int(char.asciiValue!) - Int(Character("0").asciiValue!)
            case "a"..."z" where base > 10 && base <= 36:
                value = Int(char.asciiValue!) - Int(Character("a").asciiValue!) + 10
            case "A"..."Z" where base > 10 && base <= 36:
                value = Int(char.asciiValue!) - Int(Character("A").asciiValue!) + 10
            case "a"..."z" where base > 36:
                value = Int(char.asciiValue!) - Int(Character("a").asciiValue!) + 10
            case "A"..."Z" where base > 36:
                value = Int(char.asciiValue!) - Int(Character("A").asciiValue!) + 36
            case "@" where base > 62:
                value = 62
            case "_" where base > 63:
                value = 63
            default:
                return nil
            }
            return value < base ? value : nil
        }

        // MARK: Operators

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        mutating func readOperator() throws -> ArithToken {
            guard let char = peek() else { throw ArithError.unexpectedEnd }
            let next1 = peek(1)
            let next2 = peek(2)

            switch char {
            case "+":
                if next1 == "+" { advance(); advance(); return .plusPlus }
                if next1 == "=" { advance(); advance(); return .plusAssign }
                advance(); return .plus
            case "-":
                if next1 == "-" { advance(); advance(); return .minusMinus }
                if next1 == "=" { advance(); advance(); return .minusAssign }
                advance(); return .minus
            case "*":
                if next1 == "*" {
                    if next2 == "=" {
                        advance(); advance(); advance(); return .starStarAssign
                    }
                    advance(); advance(); return .starStar
                }
                if next1 == "=" { advance(); advance(); return .starAssign }
                advance(); return .star
            case "/":
                if next1 == "=" { advance(); advance(); return .slashAssign }
                advance(); return .slash
            case "%":
                if next1 == "=" { advance(); advance(); return .percentAssign }
                advance(); return .percent
            case "<":
                if next1 == "<" {
                    if next2 == "=" {
                        advance(); advance(); advance(); return .shiftLeftAssign
                    }
                    advance(); advance(); return .shiftLeft
                }
                if next1 == "=" { advance(); advance(); return .le }
                advance(); return .lt
            case ">":
                if next1 == ">" {
                    if next2 == "=" {
                        advance(); advance(); advance(); return .shiftRightAssign
                    }
                    advance(); advance(); return .shiftRight
                }
                if next1 == "=" { advance(); advance(); return .ge }
                advance(); return .gt
            case "=":
                if next1 == "=" { advance(); advance(); return .eq }
                advance(); return .assign
            case "!":
                if next1 == "=" { advance(); advance(); return .neq }
                advance(); return .bang
            case "&":
                if next1 == "&" { advance(); advance(); return .ampAmp }
                if next1 == "=" { advance(); advance(); return .ampAssign }
                advance(); return .amp
            case "|":
                if next1 == "|" { advance(); advance(); return .barBar }
                if next1 == "=" { advance(); advance(); return .barAssign }
                advance(); return .bar
            case "^":
                if next1 == "=" { advance(); advance(); return .caretAssign }
                advance(); return .caret
            case "~":
                advance(); return .tilde
            case "?":
                advance(); return .question
            case ":":
                advance(); return .colon
            case "(":
                advance(); return .lParen
            case ")":
                advance(); return .rParen
            case ",":
                advance(); return .comma
            case "[":
                advance(); return .lBracket
            case "]":
                advance(); return .rBracket
            default:
                throw ArithError.unexpectedCharacter(char, position: index)
            }
        }
    }
}
