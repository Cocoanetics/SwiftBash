import Foundation

enum AwkTokenKind: Equatable, Hashable {
    // literals
    case number(Double)
    case string(String)
    case regex(String)
    case ident(String)
    // keywords
    case kBegin, kEnd, kIf, kElse, kWhile, kDo, kFor, kIn
    case kBreak, kContinue, kNext, kNextfile, kExit, kReturn, kDelete
    case kFunction, kPrint, kPrintf, kGetline
    // operators
    case plus, minus, star, slash, percent, caret
    // swiftlint:disable:next identifier_name - AWK comparison operator names
    case eq, ne, lt, gt, le, ge
    case match, notMatch
    // swiftlint:disable:next identifier_name - AWK logical operator `or`
    case and, or, not
    case assign, plusAssign, minusAssign, starAssign, slashAssign, percentAssign, caretAssign
    case increment, decrement
    case question, colon, comma, semicolon, newline
    case lparen, rparen, lbrace, rbrace, lbracket, rbracket
    case dollar, append, pipe
    case eof
}

struct AwkToken: Equatable {
    let kind: AwkTokenKind
    let line: Int
    let column: Int
}

// swiftlint:disable:next type_body_length - AWK lexer is one cohesive state machine
struct AwkLexer {
    private let chars: [Character]
    private var pos = 0
    private var line = 1
    private var column = 1
    private var lastTokenKind: AwkTokenKind?

    init(_ source: String) {
        self.chars = Array(source)
    }

    private static let keywords: [String: AwkTokenKind] = [
        "BEGIN": .kBegin, "END": .kEnd,
        "if": .kIf, "else": .kElse,
        "while": .kWhile, "do": .kDo,
        "for": .kFor, "in": .kIn,
        "break": .kBreak, "continue": .kContinue,
        "next": .kNext, "nextfile": .kNextfile,
        "exit": .kExit, "return": .kReturn,
        "delete": .kDelete, "function": .kFunction,
        "print": .kPrint, "printf": .kPrintf,
        "getline": .kGetline
    ]

    mutating func tokenize() throws -> [AwkToken] {
        var tokens: [AwkToken] = []
        while pos < chars.count {
            if let tok = try nextToken() {
                tokens.append(tok)
                lastTokenKind = tok.kind
            }
        }
        tokens.append(AwkToken(kind: .eof, line: line, column: column))
        return tokens
    }

    private mutating func skipWhitespace() {
        while pos < chars.count {
            let char = chars[pos]
            if char == " " || char == "\t" || char == "\r" {
                advance()
            } else if char == "\\" && pos + 1 < chars.count && chars[pos + 1] == "\n" {
                advance(); advance()                    // line continuation
            } else if char == "#" {
                while pos < chars.count && chars[pos] != "\n" { advance() }
            } else {
                break
            }
        }
    }

    private mutating func advance() {
        if pos < chars.count, chars[pos] == "\n" {
            line += 1; column = 1
        } else {
            column += 1
        }
        pos += 1
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let idx = pos + offset
        return idx < chars.count ? chars[idx] : nil
    }

    private mutating func nextToken() throws -> AwkToken? {
        skipWhitespace()
        guard pos < chars.count else { return nil }
        let startLine = line, startColumn = column
        let char = chars[pos]
        if char == "\n" { advance(); return AwkToken(kind: .newline, line: startLine, column: startColumn) }
        if char == "\"" { return try readString(startLine, startColumn) }
        if char == "/" && canBeRegex() { return try readRegex(startLine, startColumn) }
        if char.isASCII && (char.isNumber || (char == "." && peek(1)?.isNumber == true)) {
            return readNumber(startLine, startColumn)
        }
        if char.isASCII && (char.isLetter || char == "_") {
            return readIdentifier(startLine, startColumn)
        }
        return try readOperator(startLine, startColumn)
    }

    private func canBeRegex() -> Bool {
        guard let last = lastTokenKind else { return true }
        switch last {
        case .newline, .semicolon, .lbrace, .rbrace, .lparen, .lbracket, .comma,
             .assign, .plusAssign, .minusAssign, .starAssign, .slashAssign, .percentAssign, .caretAssign,
             .and, .or, .not, .match, .notMatch, .question, .colon,
             .lt, .gt, .le, .ge, .eq, .ne,
             .plus, .minus, .star, .percent, .caret,
             .kPrint, .kPrintf, .kIf, .kWhile, .kDo, .kFor, .kReturn:
            return true
        default:
            return false
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private mutating func readString(_ startLine: Int, _ startColumn: Int) throws -> AwkToken {
        advance()
        var text = ""
        while pos < chars.count && chars[pos] != "\"" {
            if chars[pos] == "\\" {
                advance()
                guard pos < chars.count else { break }
                let escape = chars[pos]; advance()
                switch escape {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "r": text.append("\r")
                case "f": text.append("\u{0C}")
                case "b": text.append("\u{08}")
                case "v": text.append("\u{0B}")
                case "a": text.append("\u{07}")
                case "\\": text.append("\\")
                case "\"": text.append("\"")
                case "/": text.append("/")
                case "x":
                    var hex = ""
                    while hex.count < 2, pos < chars.count, chars[pos].isHexDigit {
                        hex.append(chars[pos]); advance()
                    }
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        text.append(Character(scalar))
                    } else {
                        text.append("x")
                    }
                default:
                    if let ascii = escape.asciiValue, ascii >= 0x30, ascii <= 0x37 {
                        var oct = String(escape)
                        while oct.count < 3, pos < chars.count,
                              let asciiCode = chars[pos].asciiValue,
                              asciiCode >= 0x30, asciiCode <= 0x37 {
                            oct.append(chars[pos]); advance()
                        }
                        if let code = UInt32(oct, radix: 8), let scalar = Unicode.Scalar(code) {
                            text.append(Character(scalar))
                        }
                    } else {
                        text.append(escape)
                    }
                }
            } else {
                text.append(chars[pos]); advance()
            }
        }
        if pos < chars.count { advance() }   // closing quote
        return AwkToken(kind: .string(text), line: startLine, column: startColumn)
    }

    private mutating func readRegex(_ startLine: Int, _ startColumn: Int) throws -> AwkToken {
        advance()                           // opening /
        var pat = ""
        while pos < chars.count && chars[pos] != "/" {
            if chars[pos] == "\\" {
                pat.append(chars[pos]); advance()
                if pos < chars.count {
                    pat.append(chars[pos]); advance()
                }
            } else if chars[pos] == "\n" {
                break                       // unterminated; tolerate
            } else {
                pat.append(chars[pos]); advance()
            }
        }
        if pos < chars.count { advance() }
        return AwkToken(kind: .regex(expandPosixClasses(pat)), line: startLine, column: startColumn)
    }

    private mutating func readNumber(_ startLine: Int, _ startColumn: Int) -> AwkToken {
        var text = ""
        while pos < chars.count, chars[pos].isASCII, chars[pos].isNumber {
            text.append(chars[pos]); advance()
        }
        if pos < chars.count, chars[pos] == ".", peek(1)?.isNumber == true {
            text.append(chars[pos]); advance()
            while pos < chars.count, chars[pos].isASCII, chars[pos].isNumber {
                text.append(chars[pos]); advance()
            }
        }
        if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
            text.append(chars[pos]); advance()
            if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" {
                text.append(chars[pos]); advance()
            }
            while pos < chars.count, chars[pos].isASCII, chars[pos].isNumber {
                text.append(chars[pos]); advance()
            }
        }
        return AwkToken(kind: .number(Double(text) ?? 0), line: startLine, column: startColumn)
    }

    private mutating func readIdentifier(_ startLine: Int, _ startColumn: Int) -> AwkToken {
        var name = ""
        while pos < chars.count, chars[pos].isASCII, chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_" {
            name.append(chars[pos]); advance()
        }
        if let keyword = AwkLexer.keywords[name] {
            return AwkToken(kind: keyword, line: startLine, column: startColumn)
        }
        return AwkToken(kind: .ident(name), line: startLine, column: startColumn)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private mutating func readOperator(_ startLine: Int, _ startColumn: Int) throws -> AwkToken {
        let char = chars[pos]; advance()
        let next = pos < chars.count ? chars[pos] : nil
        switch char {
        case "+":
            if next == "+" { advance(); return AwkToken(kind: .increment, line: startLine, column: startColumn) }
            if next == "=" { advance(); return AwkToken(kind: .plusAssign, line: startLine, column: startColumn) }
            return AwkToken(kind: .plus, line: startLine, column: startColumn)
        case "-":
            if next == "-" { advance(); return AwkToken(kind: .decrement, line: startLine, column: startColumn) }
            if next == "=" { advance(); return AwkToken(kind: .minusAssign, line: startLine, column: startColumn) }
            return AwkToken(kind: .minus, line: startLine, column: startColumn)
        case "*":
            if next == "*" { advance(); return AwkToken(kind: .caret, line: startLine, column: startColumn) }
            if next == "=" { advance(); return AwkToken(kind: .starAssign, line: startLine, column: startColumn) }
            return AwkToken(kind: .star, line: startLine, column: startColumn)
        case "/":
            if next == "=" { advance(); return AwkToken(kind: .slashAssign, line: startLine, column: startColumn) }
            return AwkToken(kind: .slash, line: startLine, column: startColumn)
        case "%":
            if next == "=" { advance(); return AwkToken(kind: .percentAssign, line: startLine, column: startColumn) }
            return AwkToken(kind: .percent, line: startLine, column: startColumn)
        case "^":
            if next == "=" { advance(); return AwkToken(kind: .caretAssign, line: startLine, column: startColumn) }
            return AwkToken(kind: .caret, line: startLine, column: startColumn)
        case "=":
            if next == "=" { advance(); return AwkToken(kind: .eq, line: startLine, column: startColumn) }
            return AwkToken(kind: .assign, line: startLine, column: startColumn)
        case "!":
            if next == "=" { advance(); return AwkToken(kind: .ne, line: startLine, column: startColumn) }
            if next == "~" { advance(); return AwkToken(kind: .notMatch, line: startLine, column: startColumn) }
            return AwkToken(kind: .not, line: startLine, column: startColumn)
        case "<":
            if next == "=" { advance(); return AwkToken(kind: .le, line: startLine, column: startColumn) }
            return AwkToken(kind: .lt, line: startLine, column: startColumn)
        case ">":
            if next == "=" { advance(); return AwkToken(kind: .ge, line: startLine, column: startColumn) }
            if next == ">" { advance(); return AwkToken(kind: .append, line: startLine, column: startColumn) }
            return AwkToken(kind: .gt, line: startLine, column: startColumn)
        case "&":
            if next == "&" { advance(); return AwkToken(kind: .and, line: startLine, column: startColumn) }
            return AwkToken(kind: .ident("&"), line: startLine, column: startColumn)
        case "|":
            if next == "|" { advance(); return AwkToken(kind: .or, line: startLine, column: startColumn) }
            return AwkToken(kind: .pipe, line: startLine, column: startColumn)
        case "~": return AwkToken(kind: .match, line: startLine, column: startColumn)
        case "?": return AwkToken(kind: .question, line: startLine, column: startColumn)
        case ":": return AwkToken(kind: .colon, line: startLine, column: startColumn)
        case ",": return AwkToken(kind: .comma, line: startLine, column: startColumn)
        case ";": return AwkToken(kind: .semicolon, line: startLine, column: startColumn)
        case "(": return AwkToken(kind: .lparen, line: startLine, column: startColumn)
        case ")": return AwkToken(kind: .rparen, line: startLine, column: startColumn)
        case "{": return AwkToken(kind: .lbrace, line: startLine, column: startColumn)
        case "}": return AwkToken(kind: .rbrace, line: startLine, column: startColumn)
        case "[": return AwkToken(kind: .lbracket, line: startLine, column: startColumn)
        case "]": return AwkToken(kind: .rbracket, line: startLine, column: startColumn)
        case "$": return AwkToken(kind: .dollar, line: startLine, column: startColumn)
        default:
            throw AwkParseError(
                "unexpected character '\(char)' at line \(startLine):\(startColumn)")
        }
    }

    /// Expand POSIX character classes (`[[:alpha:]]` etc.) in regex
    /// patterns to ICU-friendly equivalents — `NSRegularExpression`
    /// understands them, but POSIX bracket-class form is more portable.
    private func expandPosixClasses(_ pattern: String) -> String {
        var result = pattern
        let map: [(String, String)] = [
            ("[[:space:]]", "[ \\t\\n\\r\\f\\v]"),
            ("[[:blank:]]", "[ \\t]"),
            ("[[:alpha:]]", "[a-zA-Z]"),
            ("[[:digit:]]", "[0-9]"),
            ("[[:alnum:]]", "[a-zA-Z0-9]"),
            ("[[:upper:]]", "[A-Z]"),
            ("[[:lower:]]", "[a-z]"),
            ("[[:xdigit:]]", "[0-9A-Fa-f]"),
            ("[[:graph:]]", "[!-~]"),
            ("[[:print:]]", "[ -~]"),
            ("[[:cntrl:]]", "[\\x00-\\x1f\\x7f]"),
            ("[[:punct:]]", "[!\"#$%&'()*+,\\-./:;<=>?@\\[\\]\\\\^_`{|}~]")
        ]
        for (src, dst) in map {
            result = result.replacingOccurrences(of: src, with: dst)
        }
        return result
    }
}
