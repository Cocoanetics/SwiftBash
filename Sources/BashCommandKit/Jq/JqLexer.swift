import Foundation

public struct JqError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// jq throws a value (most builtins use a string, but `error(v)`
/// preserves the original value). Caught by `try` / `?`.
public struct JqThrown: Error, CustomStringConvertible {
    public let value: JqValue
    public init(_ value: JqValue) { self.value = value }
    public var description: String {
        switch value {
        case .string(let str): return str
        default: return JqFormatter.compact(value)
        }
    }
}

/// `break $label` propagates as an error caught by the matching `label`.
struct JqBreak: Error {
    let label: String
    var partial: [JqValue] = []
}

enum JqTokenKind: Equatable, Hashable {
    case dot, dotdot, pipe, comma, colon, semicolon
    case lparen, rparen, lbracket, rbracket, lbrace, rbrace
    case question, plus, minus, star, slash, percent
    // Two-letter comparison op spellings mirror jq's source-level tokens.
    // swiftlint:disable:next identifier_name
    case eq, ne, lt, le, gt, ge
    // `or`, `not_` mirror jq operator names.
    // swiftlint:disable:next identifier_name
    case and, or, not_
    case alt        // //
    case assign     // =
    case updateAdd, updateSub, updateMul, updateDiv, updateMod, updateAlt, updatePipe
    case ident(String)
    case format(String)    // @something — preserved literally including '@'
    case variable(String)  // $name (including '$')
    case number(Double)
    case string(String)    // unprocessed for interpolation - raw inner content
    // `if_`, `else_` mirror Swift-reserved keywords used as jq tokens.
    // swiftlint:disable:next identifier_name
    case if_, then, elif, else_, end
    // `as_`, `try_`, `catch_` mirror Swift-reserved keywords used as jq tokens.
    // swiftlint:disable:next identifier_name
    case as_, try_, catch_
    // `true_`, `false_` mirror Swift-reserved literals used as jq tokens.
    // swiftlint:disable:next identifier_name
    case true_, false_, null
    case reduce, foreach
    // `break_` mirrors a Swift-reserved keyword used as a jq token.
    // swiftlint:disable:next identifier_name
    case label, break_
    case def
    case eof
}

struct JqToken: Equatable {
    let kind: JqTokenKind
    let pos: Int
}

/// Tokenize a jq filter expression.
struct JqLexer {
    private let source: [Character]
    private var pos = 0
    private var startOfToken = 0

    init(_ source: String) {
        self.source = Array(source)
    }

    mutating func tokenize() throws -> [JqToken] {
        var tokens: [JqToken] = []
        while let tok = try nextToken() {
            tokens.append(tok)
        }
        tokens.append(JqToken(kind: .eof, pos: pos))
        return tokens
    }

    private static let keywords: [String: JqTokenKind] = [
        "and": .and, "or": .or, "not": .not_,
        "if": .if_, "then": .then, "elif": .elif, "else": .else_, "end": .end,
        "as": .as_, "try": .try_, "catch": .catch_,
        "true": .true_, "false": .false_, "null": .null,
        "reduce": .reduce, "foreach": .foreach,
        "label": .label, "break": .break_,
        "def": .def
    ]

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private mutating func nextToken() throws -> JqToken? {
        while pos < source.count {
            startOfToken = pos
            let char = source[pos]
            // whitespace
            if char == " " || char == "\t" || char == "\n" || char == "\r" {
                pos += 1
                continue
            }
            // comments
            if char == "#" {
                while pos < source.count && source[pos] != "\n" { pos += 1 }
                continue
            }
            // multi-char operators
            if char == "." && peek(1) == "." {
                pos += 2
                return JqToken(kind: .dotdot, pos: startOfToken)
            }
            if char == "=" && peek(1) == "=" {
                pos += 2; return JqToken(kind: .eq, pos: startOfToken)
            }
            if char == "!" && peek(1) == "=" {
                pos += 2; return JqToken(kind: .ne, pos: startOfToken)
            }
            if char == "<" && peek(1) == "=" {
                pos += 2; return JqToken(kind: .le, pos: startOfToken)
            }
            if char == ">" && peek(1) == "=" {
                pos += 2; return JqToken(kind: .ge, pos: startOfToken)
            }
            if char == "/" && peek(1) == "/" {
                pos += 2
                if peek(0) == "=" { pos += 1; return JqToken(kind: .updateAlt, pos: startOfToken) }
                return JqToken(kind: .alt, pos: startOfToken)
            }
            if char == "+" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateAdd, pos: startOfToken) }
            if char == "-" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateSub, pos: startOfToken) }
            if char == "*" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateMul, pos: startOfToken) }
            if char == "/" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateDiv, pos: startOfToken) }
            if char == "%" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateMod, pos: startOfToken) }
            if char == "|" && peek(1) == "=" { pos += 2; return JqToken(kind: .updatePipe, pos: startOfToken) }
            if char == "=" { pos += 1; return JqToken(kind: .assign, pos: startOfToken) }

            switch char {
            case ".": pos += 1; return JqToken(kind: .dot, pos: startOfToken)
            case "|": pos += 1; return JqToken(kind: .pipe, pos: startOfToken)
            case ",": pos += 1; return JqToken(kind: .comma, pos: startOfToken)
            case ":": pos += 1; return JqToken(kind: .colon, pos: startOfToken)
            case ";": pos += 1; return JqToken(kind: .semicolon, pos: startOfToken)
            case "(": pos += 1; return JqToken(kind: .lparen, pos: startOfToken)
            case ")": pos += 1; return JqToken(kind: .rparen, pos: startOfToken)
            case "[": pos += 1; return JqToken(kind: .lbracket, pos: startOfToken)
            case "]": pos += 1; return JqToken(kind: .rbracket, pos: startOfToken)
            case "{": pos += 1; return JqToken(kind: .lbrace, pos: startOfToken)
            case "}": pos += 1; return JqToken(kind: .rbrace, pos: startOfToken)
            case "?": pos += 1; return JqToken(kind: .question, pos: startOfToken)
            case "+": pos += 1; return JqToken(kind: .plus, pos: startOfToken)
            case "-": pos += 1; return JqToken(kind: .minus, pos: startOfToken)
            case "*": pos += 1; return JqToken(kind: .star, pos: startOfToken)
            case "/": pos += 1; return JqToken(kind: .slash, pos: startOfToken)
            case "%": pos += 1; return JqToken(kind: .percent, pos: startOfToken)
            case "<": pos += 1; return JqToken(kind: .lt, pos: startOfToken)
            case ">": pos += 1; return JqToken(kind: .gt, pos: startOfToken)
            default: break
            }

            // numbers
            if char.isASCII && (char.isNumber || (char == "." && pos + 1 < source.count && source[pos + 1].isNumber)) {
                return try readNumber()
            }

            // strings
            if char == "\"" {
                return try readString()
            }

            // identifiers, $vars, @formats
            if isIdentStart(char) || char == "$" || char == "@" {
                return readIdentifier()
            }

            throw JqError("jq: parse error: Unexpected character '\(char)' at position \(pos)")
        }
        return nil
    }

    private func peek(_ offset: Int) -> Character? {
        let idx = pos + offset
        return idx < source.count ? source[idx] : nil
    }

    private mutating func readNumber() throws -> JqToken {
        var buf = ""
        while pos < source.count {
            let char = source[pos]
            if char.isNumber || char == "." {
                buf.append(char); pos += 1
            } else if char == "e" || char == "E" {
                buf.append(char); pos += 1
                if pos < source.count && (source[pos] == "+" || source[pos] == "-") {
                    buf.append(source[pos]); pos += 1
                }
            } else {
                break
            }
        }
        guard let num = Double(buf) else {
            throw JqError("jq: parse error: invalid number '\(buf)'")
        }
        return JqToken(kind: .number(num), pos: startOfToken)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private mutating func readString() throws -> JqToken {
        pos += 1  // consume opening quote
        var buf = ""
        while pos < source.count && source[pos] != "\"" {
            let char = source[pos]
            if char == "\\" {
                pos += 1
                if pos >= source.count { break }
                let esc = source[pos]
                switch esc {
                case "n": buf.append("\n")
                case "r": buf.append("\r")
                case "t": buf.append("\t")
                case "b": buf.append("\u{08}")
                case "f": buf.append("\u{0C}")
                case "/": buf.append("/")
                case "\\": buf.append("\\")
                case "\"": buf.append("\"")
                case "(": buf.append("\\(") // preserve for interpolation
                case "u":
                    pos += 1
                    var hex = ""
                    for _ in 0..<4 {
                        guard pos < source.count else { break }
                        hex.append(source[pos]); pos += 1
                    }
                    pos -= 1
                    if let scalar = UInt32(hex, radix: 16),
                       let unicodeScalar = Unicode.Scalar(scalar) {
                        buf.append(Character(unicodeScalar))
                    }
                default: buf.append(esc)
                }
                pos += 1
            } else {
                buf.append(char); pos += 1
            }
        }
        if pos < source.count { pos += 1 }  // closing quote
        return JqToken(kind: .string(buf), pos: startOfToken)
    }

    private mutating func readIdentifier() -> JqToken {
        var buf = ""
        // first char might be $ or @ or alpha
        buf.append(source[pos]); pos += 1
        while pos < source.count, isIdentContinue(source[pos]) {
            buf.append(source[pos]); pos += 1
        }
        if buf.hasPrefix("$") {
            return JqToken(kind: .variable(buf), pos: startOfToken)
        }
        if buf.hasPrefix("@") {
            return JqToken(kind: .format(buf), pos: startOfToken)
        }
        if let keyword = JqLexer.keywords[buf] {
            return JqToken(kind: keyword, pos: startOfToken)
        }
        return JqToken(kind: .ident(buf), pos: startOfToken)
    }

    private func isIdentStart(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char == "_")
    }

    private func isIdentContinue(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber || char == "_")
    }
}
