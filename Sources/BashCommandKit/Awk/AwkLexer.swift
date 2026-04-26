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
    case eq, ne, lt, gt, le, ge
    case match, notMatch
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

struct AwkLexer {
    private let chars: [Character]
    private var pos = 0
    private var line = 1
    private var column = 1
    private var lastTokenKind: AwkTokenKind? = nil

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
        "getline": .kGetline,
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
            let c = chars[pos]
            if c == " " || c == "\t" || c == "\r" {
                advance()
            } else if c == "\\" && pos + 1 < chars.count && chars[pos + 1] == "\n" {
                advance(); advance()                    // line continuation
            } else if c == "#" {
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
        let i = pos + offset
        return i < chars.count ? chars[i] : nil
    }

    private mutating func nextToken() throws -> AwkToken? {
        skipWhitespace()
        guard pos < chars.count else { return nil }
        let startLine = line, startColumn = column
        let c = chars[pos]
        if c == "\n" { advance(); return AwkToken(kind: .newline, line: startLine, column: startColumn) }
        if c == "\"" { return try readString(startLine, startColumn) }
        if c == "/" && canBeRegex() { return try readRegex(startLine, startColumn) }
        if c.isASCII && (c.isNumber || (c == "." && peek(1)?.isNumber == true)) {
            return readNumber(startLine, startColumn)
        }
        if c.isASCII && (c.isLetter || c == "_") {
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

    private mutating func readString(_ sl: Int, _ sc: Int) throws -> AwkToken {
        advance()
        var s = ""
        while pos < chars.count && chars[pos] != "\"" {
            if chars[pos] == "\\" {
                advance()
                guard pos < chars.count else { break }
                let e = chars[pos]; advance()
                switch e {
                case "n": s.append("\n")
                case "t": s.append("\t")
                case "r": s.append("\r")
                case "f": s.append("\u{0C}")
                case "b": s.append("\u{08}")
                case "v": s.append("\u{0B}")
                case "a": s.append("\u{07}")
                case "\\": s.append("\\")
                case "\"": s.append("\"")
                case "/": s.append("/")
                case "x":
                    var hex = ""
                    while hex.count < 2, pos < chars.count, chars[pos].isHexDigit {
                        hex.append(chars[pos]); advance()
                    }
                    if let n = UInt32(hex, radix: 16), let u = Unicode.Scalar(n) {
                        s.append(Character(u))
                    } else {
                        s.append("x")
                    }
                default:
                    if let v = e.asciiValue, v >= 0x30, v <= 0x37 {
                        var oct = String(e)
                        while oct.count < 3, pos < chars.count,
                              let v2 = chars[pos].asciiValue, v2 >= 0x30, v2 <= 0x37 {
                            oct.append(chars[pos]); advance()
                        }
                        if let n = UInt32(oct, radix: 8), let u = Unicode.Scalar(n) {
                            s.append(Character(u))
                        }
                    } else {
                        s.append(e)
                    }
                }
            } else {
                s.append(chars[pos]); advance()
            }
        }
        if pos < chars.count { advance() }   // closing quote
        return AwkToken(kind: .string(s), line: sl, column: sc)
    }

    private mutating func readRegex(_ sl: Int, _ sc: Int) throws -> AwkToken {
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
        return AwkToken(kind: .regex(expandPosixClasses(pat)), line: sl, column: sc)
    }

    private mutating func readNumber(_ sl: Int, _ sc: Int) -> AwkToken {
        var s = ""
        while pos < chars.count, chars[pos].isASCII, chars[pos].isNumber {
            s.append(chars[pos]); advance()
        }
        if pos < chars.count, chars[pos] == ".", peek(1)?.isNumber == true {
            s.append(chars[pos]); advance()
            while pos < chars.count, chars[pos].isASCII, chars[pos].isNumber {
                s.append(chars[pos]); advance()
            }
        }
        if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
            s.append(chars[pos]); advance()
            if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" {
                s.append(chars[pos]); advance()
            }
            while pos < chars.count, chars[pos].isASCII, chars[pos].isNumber {
                s.append(chars[pos]); advance()
            }
        }
        return AwkToken(kind: .number(Double(s) ?? 0), line: sl, column: sc)
    }

    private mutating func readIdentifier(_ sl: Int, _ sc: Int) -> AwkToken {
        var name = ""
        while pos < chars.count, chars[pos].isASCII, (chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_") {
            name.append(chars[pos]); advance()
        }
        if let kw = AwkLexer.keywords[name] {
            return AwkToken(kind: kw, line: sl, column: sc)
        }
        return AwkToken(kind: .ident(name), line: sl, column: sc)
    }

    private mutating func readOperator(_ sl: Int, _ sc: Int) throws -> AwkToken {
        let c = chars[pos]; advance()
        let next = pos < chars.count ? chars[pos] : nil
        switch c {
        case "+":
            if next == "+" { advance(); return AwkToken(kind: .increment, line: sl, column: sc) }
            if next == "=" { advance(); return AwkToken(kind: .plusAssign, line: sl, column: sc) }
            return AwkToken(kind: .plus, line: sl, column: sc)
        case "-":
            if next == "-" { advance(); return AwkToken(kind: .decrement, line: sl, column: sc) }
            if next == "=" { advance(); return AwkToken(kind: .minusAssign, line: sl, column: sc) }
            return AwkToken(kind: .minus, line: sl, column: sc)
        case "*":
            if next == "*" { advance(); return AwkToken(kind: .caret, line: sl, column: sc) }
            if next == "=" { advance(); return AwkToken(kind: .starAssign, line: sl, column: sc) }
            return AwkToken(kind: .star, line: sl, column: sc)
        case "/":
            if next == "=" { advance(); return AwkToken(kind: .slashAssign, line: sl, column: sc) }
            return AwkToken(kind: .slash, line: sl, column: sc)
        case "%":
            if next == "=" { advance(); return AwkToken(kind: .percentAssign, line: sl, column: sc) }
            return AwkToken(kind: .percent, line: sl, column: sc)
        case "^":
            if next == "=" { advance(); return AwkToken(kind: .caretAssign, line: sl, column: sc) }
            return AwkToken(kind: .caret, line: sl, column: sc)
        case "=":
            if next == "=" { advance(); return AwkToken(kind: .eq, line: sl, column: sc) }
            return AwkToken(kind: .assign, line: sl, column: sc)
        case "!":
            if next == "=" { advance(); return AwkToken(kind: .ne, line: sl, column: sc) }
            if next == "~" { advance(); return AwkToken(kind: .notMatch, line: sl, column: sc) }
            return AwkToken(kind: .not, line: sl, column: sc)
        case "<":
            if next == "=" { advance(); return AwkToken(kind: .le, line: sl, column: sc) }
            return AwkToken(kind: .lt, line: sl, column: sc)
        case ">":
            if next == "=" { advance(); return AwkToken(kind: .ge, line: sl, column: sc) }
            if next == ">" { advance(); return AwkToken(kind: .append, line: sl, column: sc) }
            return AwkToken(kind: .gt, line: sl, column: sc)
        case "&":
            if next == "&" { advance(); return AwkToken(kind: .and, line: sl, column: sc) }
            return AwkToken(kind: .ident("&"), line: sl, column: sc)
        case "|":
            if next == "|" { advance(); return AwkToken(kind: .or, line: sl, column: sc) }
            return AwkToken(kind: .pipe, line: sl, column: sc)
        case "~": return AwkToken(kind: .match, line: sl, column: sc)
        case "?": return AwkToken(kind: .question, line: sl, column: sc)
        case ":": return AwkToken(kind: .colon, line: sl, column: sc)
        case ",": return AwkToken(kind: .comma, line: sl, column: sc)
        case ";": return AwkToken(kind: .semicolon, line: sl, column: sc)
        case "(": return AwkToken(kind: .lparen, line: sl, column: sc)
        case ")": return AwkToken(kind: .rparen, line: sl, column: sc)
        case "{": return AwkToken(kind: .lbrace, line: sl, column: sc)
        case "}": return AwkToken(kind: .rbrace, line: sl, column: sc)
        case "[": return AwkToken(kind: .lbracket, line: sl, column: sc)
        case "]": return AwkToken(kind: .rbracket, line: sl, column: sc)
        case "$": return AwkToken(kind: .dollar, line: sl, column: sc)
        default:
            throw AwkParseError("unexpected character '\(c)' at line \(sl):\(sc)")
        }
    }

    /// Expand POSIX character classes (`[[:alpha:]]` etc.) in regex
    /// patterns to ICU-friendly equivalents — `NSRegularExpression`
    /// understands them, but POSIX bracket-class form is more portable.
    private func expandPosixClasses(_ p: String) -> String {
        var s = p
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
            ("[[:punct:]]", "[!\"#$%&'()*+,\\-./:;<=>?@\\[\\]\\\\^_`{|}~]"),
        ]
        for (src, dst) in map {
            s = s.replacingOccurrences(of: src, with: dst)
        }
        return s
    }
}
