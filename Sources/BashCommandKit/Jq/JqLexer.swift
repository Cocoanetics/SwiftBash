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
        case .string(let s): return s
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
    case eq, ne, lt, le, gt, ge
    case and, or, not_
    case alt        // //
    case assign     // =
    case updateAdd, updateSub, updateMul, updateDiv, updateMod, updateAlt, updatePipe
    case ident(String)
    case format(String)    // @something — preserved literally including '@'
    case variable(String)  // $name (including '$')
    case number(Double)
    case string(String)    // unprocessed for interpolation - raw inner content
    case if_, then, elif, else_, end
    case as_, try_, catch_
    case true_, false_, null
    case reduce, foreach
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

    init(_ s: String) {
        self.source = Array(s)
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
        "def": .def,
    ]

    private mutating func nextToken() throws -> JqToken? {
        while pos < source.count {
            startOfToken = pos
            let c = source[pos]
            // whitespace
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                pos += 1
                continue
            }
            // comments
            if c == "#" {
                while pos < source.count && source[pos] != "\n" { pos += 1 }
                continue
            }
            // multi-char operators
            if c == "." && peek(1) == "." {
                pos += 2
                return JqToken(kind: .dotdot, pos: startOfToken)
            }
            if c == "=" && peek(1) == "=" {
                pos += 2; return JqToken(kind: .eq, pos: startOfToken)
            }
            if c == "!" && peek(1) == "=" {
                pos += 2; return JqToken(kind: .ne, pos: startOfToken)
            }
            if c == "<" && peek(1) == "=" {
                pos += 2; return JqToken(kind: .le, pos: startOfToken)
            }
            if c == ">" && peek(1) == "=" {
                pos += 2; return JqToken(kind: .ge, pos: startOfToken)
            }
            if c == "/" && peek(1) == "/" {
                pos += 2
                if peek(0) == "=" { pos += 1; return JqToken(kind: .updateAlt, pos: startOfToken) }
                return JqToken(kind: .alt, pos: startOfToken)
            }
            if c == "+" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateAdd, pos: startOfToken) }
            if c == "-" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateSub, pos: startOfToken) }
            if c == "*" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateMul, pos: startOfToken) }
            if c == "/" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateDiv, pos: startOfToken) }
            if c == "%" && peek(1) == "=" { pos += 2; return JqToken(kind: .updateMod, pos: startOfToken) }
            if c == "|" && peek(1) == "=" { pos += 2; return JqToken(kind: .updatePipe, pos: startOfToken) }
            if c == "=" { pos += 1; return JqToken(kind: .assign, pos: startOfToken) }

            switch c {
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
            if c.isASCII && (c.isNumber || (c == "." && pos + 1 < source.count && source[pos + 1].isNumber)) {
                return try readNumber()
            }

            // strings
            if c == "\"" {
                return try readString()
            }

            // identifiers, $vars, @formats
            if isIdentStart(c) || c == "$" || c == "@" {
                return readIdentifier()
            }

            throw JqError("jq: parse error: Unexpected character '\(c)' at position \(pos)")
        }
        return nil
    }

    private func peek(_ offset: Int) -> Character? {
        let i = pos + offset
        return i < source.count ? source[i] : nil
    }

    private mutating func readNumber() throws -> JqToken {
        var s = ""
        while pos < source.count {
            let c = source[pos]
            if c.isNumber || c == "." {
                s.append(c); pos += 1
            } else if c == "e" || c == "E" {
                s.append(c); pos += 1
                if pos < source.count && (source[pos] == "+" || source[pos] == "-") {
                    s.append(source[pos]); pos += 1
                }
            } else {
                break
            }
        }
        guard let n = Double(s) else {
            throw JqError("jq: parse error: invalid number '\(s)'")
        }
        return JqToken(kind: .number(n), pos: startOfToken)
    }

    private mutating func readString() throws -> JqToken {
        pos += 1  // consume opening quote
        var s = ""
        while pos < source.count && source[pos] != "\"" {
            let c = source[pos]
            if c == "\\" {
                pos += 1
                if pos >= source.count { break }
                let e = source[pos]
                switch e {
                case "n": s.append("\n")
                case "r": s.append("\r")
                case "t": s.append("\t")
                case "b": s.append("\u{08}")
                case "f": s.append("\u{0C}")
                case "/": s.append("/")
                case "\\": s.append("\\")
                case "\"": s.append("\"")
                case "(": s.append("\\("); // preserve for interpolation
                case "u":
                    pos += 1
                    var hex = ""
                    for _ in 0..<4 {
                        guard pos < source.count else { break }
                        hex.append(source[pos]); pos += 1
                    }
                    pos -= 1
                    if let scalar = UInt32(hex, radix: 16),
                       let u = Unicode.Scalar(scalar) {
                        s.append(Character(u))
                    }
                default: s.append(e)
                }
                pos += 1
            } else {
                s.append(c); pos += 1
            }
        }
        if pos < source.count { pos += 1 }  // closing quote
        return JqToken(kind: .string(s), pos: startOfToken)
    }

    private mutating func readIdentifier() -> JqToken {
        var s = ""
        // first char might be $ or @ or alpha
        s.append(source[pos]); pos += 1
        while pos < source.count, isIdentContinue(source[pos]) {
            s.append(source[pos]); pos += 1
        }
        if s.hasPrefix("$") {
            return JqToken(kind: .variable(s), pos: startOfToken)
        }
        if s.hasPrefix("@") {
            return JqToken(kind: .format(s), pos: startOfToken)
        }
        if let kw = JqLexer.keywords[s] {
            return JqToken(kind: kw, pos: startOfToken)
        }
        return JqToken(kind: .ident(s), pos: startOfToken)
    }

    private func isIdentStart(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c == "_")
    }

    private func isIdentContinue(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_")
    }
}
