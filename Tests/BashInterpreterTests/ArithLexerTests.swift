import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct ArithLexerTests {

    // Helper: tokenise and strip the trailing .eof.
    private func lex(_ source: String,
                     sourceLocation: SourceLocation = #_sourceLocation) -> [ArithToken] {
        do {
            var toks = try ArithLexer.tokenize(source)
            #expect(toks.last == .eof, sourceLocation: sourceLocation)
            toks.removeLast()
            return toks
        } catch {
            Issue.record("tokenize failed: \(error)", sourceLocation: sourceLocation)
            return []
        }
    }

    // MARK: Numeric literals

    @Test func decimal() {
        #expect(lex("0") == [.int(0)])
        #expect(lex("42") == [.int(42)])
        #expect(lex("1234567890") == [.int(1234567890)])
    }

    @Test func hexadecimal() {
        #expect(lex("0x0") == [.int(0)])
        #expect(lex("0x7f") == [.int(127)])
        #expect(lex("0X7F") == [.int(127)])
        #expect(lex("0xFF") == [.int(255)])
        #expect(lex("0xdeadbeef") == [.int(3735928559)])
    }

    @Test func octal() {
        #expect(lex("010") == [.int(8)])
        #expect(lex("0777") == [.int(511)])
        // Octal with a non-octal digit is an error.
        #expect(throws: (any Error).self) { try ArithLexer.tokenize("0123456789") }
    }

    @Test func baseHashN() {
        #expect(lex("2#1010") == [.int(10)])
        #expect(lex("16#ff") == [.int(255)])
        #expect(lex("16#FF") == [.int(255)])
        #expect(lex("3#21") == [.int(7)])
        // Digit out of range for base:
        #expect(throws: (any Error).self) { try ArithLexer.tokenize("2#2") }
    }

    @Test func baseOutOfRange() {
        #expect(throws: (any Error).self) { try ArithLexer.tokenize("1#0") }
        #expect(throws: (any Error).self) { try ArithLexer.tokenize("65#0") }
    }

    @Test func base64LettersCoverAllDigits() throws {
        // In base-64: 10→'a', 35→'z', 36→'A', 61→'Z', 62→'@', 63→'_'.
        #expect(lex("64#a") == [.int(10)])
        #expect(lex("64#z") == [.int(35)])
        #expect(lex("64#A") == [.int(36)])
        #expect(lex("64#Z") == [.int(61)])
        #expect(lex("64#@") == [.int(62)])
        #expect(lex("64#_") == [.int(63)])
    }

    // MARK: Identifiers and variable references

    @Test func identifiers() {
        #expect(lex("x") == [.ident("x")])
        #expect(lex("foo_bar") == [.ident("foo_bar")])
        #expect(lex("_private") == [.ident("_private")])
        #expect(lex("x1 x2") == [.ident("x1"), .ident("x2")])
    }

    @Test func dollarNameAlsoWorks() {
        // Inside $((…)) bash allows $name; the lexer strips the $.
        #expect(lex("$x") == [.ident("x")])
        #expect(lex("$foo + 1") == [.ident("foo"), .plus, .int(1)])
    }

    // MARK: Single-char operators

    @Test func arithmeticOps() {
        #expect(lex("1+2") == [.int(1), .plus, .int(2)])
        #expect(lex("1-2") == [.int(1), .minus, .int(2)])
        #expect(lex("1*2") == [.int(1), .star, .int(2)])
        #expect(lex("1/2") == [.int(1), .slash, .int(2)])
        #expect(lex("1%2") == [.int(1), .percent, .int(2)])
        #expect(lex("2**3") == [.int(2), .starStar, .int(3)])
    }

    @Test func comparison() {
        #expect(lex("1<2") == [.int(1), .lt, .int(2)])
        #expect(lex("1<=2") == [.int(1), .le, .int(2)])
        #expect(lex("1>=2") == [.int(1), .ge, .int(2)])
        #expect(lex("1==2") == [.int(1), .eq, .int(2)])
        #expect(lex("1!=2") == [.int(1), .neq, .int(2)])
    }

    @Test func logicalAndBitwise() {
        #expect(lex("a&&b") == [.ident("a"), .ampAmp, .ident("b")])
        #expect(lex("a||b") == [.ident("a"), .barBar, .ident("b")])
        #expect(lex("!a")   == [.bang, .ident("a")])
        #expect(lex("a&b")  == [.ident("a"), .amp, .ident("b")])
        #expect(lex("a|b")  == [.ident("a"), .bar, .ident("b")])
        #expect(lex("a^b")  == [.ident("a"), .caret, .ident("b")])
        #expect(lex("~a")   == [.tilde, .ident("a")])
        #expect(lex("a<<b") == [.ident("a"), .shiftLeft, .ident("b")])
        #expect(lex("a>>b") == [.ident("a"), .shiftRight, .ident("b")])
    }

    // MARK: Assignments and inc/dec

    @Test func assignmentOperators() {
        #expect(lex("x=1")   == [.ident("x"), .assign, .int(1)])
        #expect(lex("x+=1")  == [.ident("x"), .plusAssign, .int(1)])
        #expect(lex("x-=1")  == [.ident("x"), .minusAssign, .int(1)])
        #expect(lex("x*=1")  == [.ident("x"), .starAssign, .int(1)])
        #expect(lex("x/=1")  == [.ident("x"), .slashAssign, .int(1)])
        #expect(lex("x%=1")  == [.ident("x"), .percentAssign, .int(1)])
        #expect(lex("x**=1") == [.ident("x"), .starStarAssign, .int(1)])
        #expect(lex("x<<=1") == [.ident("x"), .shiftLeftAssign, .int(1)])
        #expect(lex("x>>=1") == [.ident("x"), .shiftRightAssign, .int(1)])
        #expect(lex("x&=1")  == [.ident("x"), .ampAssign, .int(1)])
        #expect(lex("x^=1")  == [.ident("x"), .caretAssign, .int(1)])
        #expect(lex("x|=1")  == [.ident("x"), .barAssign, .int(1)])
    }

    @Test func incrementDecrement() {
        #expect(lex("x++") == [.ident("x"), .plusPlus])
        #expect(lex("x--") == [.ident("x"), .minusMinus])
        #expect(lex("++x") == [.plusPlus, .ident("x")])
        #expect(lex("--x") == [.minusMinus, .ident("x")])
    }

    // MARK: Grouping, ternary, comma

    @Test func punctuation() {
        #expect(lex("(1)") == [.lParen, .int(1), .rParen])
        #expect(lex("a ? b : c")
                == [.ident("a"), .question, .ident("b"), .colon, .ident("c")])
        #expect(lex("a, b") == [.ident("a"), .comma, .ident("b")])
    }

    // MARK: Whitespace

    @Test func ignoresWhitespace() {
        #expect(lex("  1  +  2  ") == [.int(1), .plus, .int(2)])
        #expect(lex("\t1\n+\t2\n") == [.int(1), .plus, .int(2)])
    }

    // MARK: Errors

    @Test func unexpectedCharacter() {
        let err = #expect(throws: (any Error).self) { try ArithLexer.tokenize("1 @ 2") }
        #expect(err is ArithError, "\(String(describing: err))")
    }
}
