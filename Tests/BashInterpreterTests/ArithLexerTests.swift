import XCTest
@testable import BashInterpreter

final class ArithLexerTests: XCTestCase {

    // Helper: tokenise and strip the trailing .eof.
    private func lex(_ s: String,
                     file: StaticString = #filePath,
                     line: UInt = #line) -> [ArithToken] {
        do {
            var toks = try ArithLexer.tokenize(s)
            XCTAssertEqual(toks.last, .eof, file: file, line: line)
            toks.removeLast()
            return toks
        } catch {
            XCTFail("tokenize failed: \(error)", file: file, line: line)
            return []
        }
    }

    // MARK: Numeric literals

    func testDecimal() {
        XCTAssertEqual(lex("0"), [.int(0)])
        XCTAssertEqual(lex("42"), [.int(42)])
        XCTAssertEqual(lex("1234567890"), [.int(1234567890)])
    }

    func testHexadecimal() {
        XCTAssertEqual(lex("0x0"), [.int(0)])
        XCTAssertEqual(lex("0x7f"), [.int(127)])
        XCTAssertEqual(lex("0X7F"), [.int(127)])
        XCTAssertEqual(lex("0xFF"), [.int(255)])
        XCTAssertEqual(lex("0xdeadbeef"), [.int(3735928559)])
    }

    func testOctal() {
        XCTAssertEqual(lex("010"), [.int(8)])
        XCTAssertEqual(lex("0777"), [.int(511)])
        // Octal with a non-octal digit is an error.
        XCTAssertThrowsError(try ArithLexer.tokenize("0123456789"))
    }

    func testBaseHashN() {
        XCTAssertEqual(lex("2#1010"), [.int(10)])
        XCTAssertEqual(lex("16#ff"), [.int(255)])
        XCTAssertEqual(lex("16#FF"), [.int(255)])
        XCTAssertEqual(lex("3#21"), [.int(7)])
        // Digit out of range for base:
        XCTAssertThrowsError(try ArithLexer.tokenize("2#2"))
    }

    func testBaseOutOfRange() {
        XCTAssertThrowsError(try ArithLexer.tokenize("1#0"))
        XCTAssertThrowsError(try ArithLexer.tokenize("65#0"))
    }

    func testBase64LettersCoverAllDigits() throws {
        // In base-64: 10→'a', 35→'z', 36→'A', 61→'Z', 62→'@', 63→'_'.
        XCTAssertEqual(lex("64#a"),  [.int(10)])
        XCTAssertEqual(lex("64#z"),  [.int(35)])
        XCTAssertEqual(lex("64#A"),  [.int(36)])
        XCTAssertEqual(lex("64#Z"),  [.int(61)])
        XCTAssertEqual(lex("64#@"),  [.int(62)])
        XCTAssertEqual(lex("64#_"),  [.int(63)])
    }

    // MARK: Identifiers and variable references

    func testIdentifiers() {
        XCTAssertEqual(lex("x"), [.ident("x")])
        XCTAssertEqual(lex("foo_bar"), [.ident("foo_bar")])
        XCTAssertEqual(lex("_private"), [.ident("_private")])
        XCTAssertEqual(lex("x1 x2"), [.ident("x1"), .ident("x2")])
    }

    func testDollarNameAlsoWorks() {
        // Inside $((…)) bash allows $name; the lexer strips the $.
        XCTAssertEqual(lex("$x"), [.ident("x")])
        XCTAssertEqual(lex("$foo + 1"), [.ident("foo"), .plus, .int(1)])
    }

    // MARK: Single-char operators

    func testArithmeticOps() {
        XCTAssertEqual(lex("1+2"),  [.int(1), .plus,  .int(2)])
        XCTAssertEqual(lex("1-2"),  [.int(1), .minus, .int(2)])
        XCTAssertEqual(lex("1*2"),  [.int(1), .star,  .int(2)])
        XCTAssertEqual(lex("1/2"),  [.int(1), .slash, .int(2)])
        XCTAssertEqual(lex("1%2"),  [.int(1), .percent, .int(2)])
        XCTAssertEqual(lex("2**3"), [.int(2), .starStar, .int(3)])
    }

    func testComparison() {
        XCTAssertEqual(lex("1<2"),  [.int(1), .lt, .int(2)])
        XCTAssertEqual(lex("1<=2"), [.int(1), .le, .int(2)])
        XCTAssertEqual(lex("1>=2"), [.int(1), .ge, .int(2)])
        XCTAssertEqual(lex("1==2"), [.int(1), .eq, .int(2)])
        XCTAssertEqual(lex("1!=2"), [.int(1), .neq, .int(2)])
    }

    func testLogicalAndBitwise() {
        XCTAssertEqual(lex("a&&b"), [.ident("a"), .ampAmp, .ident("b")])
        XCTAssertEqual(lex("a||b"), [.ident("a"), .barBar, .ident("b")])
        XCTAssertEqual(lex("!a"),   [.bang, .ident("a")])
        XCTAssertEqual(lex("a&b"),  [.ident("a"), .amp, .ident("b")])
        XCTAssertEqual(lex("a|b"),  [.ident("a"), .bar, .ident("b")])
        XCTAssertEqual(lex("a^b"),  [.ident("a"), .caret, .ident("b")])
        XCTAssertEqual(lex("~a"),   [.tilde, .ident("a")])
        XCTAssertEqual(lex("a<<b"), [.ident("a"), .shiftLeft, .ident("b")])
        XCTAssertEqual(lex("a>>b"), [.ident("a"), .shiftRight, .ident("b")])
    }

    // MARK: Assignments and inc/dec

    func testAssignmentOperators() {
        XCTAssertEqual(lex("x=1"),   [.ident("x"), .assign, .int(1)])
        XCTAssertEqual(lex("x+=1"),  [.ident("x"), .plusAssign, .int(1)])
        XCTAssertEqual(lex("x-=1"),  [.ident("x"), .minusAssign, .int(1)])
        XCTAssertEqual(lex("x*=1"),  [.ident("x"), .starAssign, .int(1)])
        XCTAssertEqual(lex("x/=1"),  [.ident("x"), .slashAssign, .int(1)])
        XCTAssertEqual(lex("x%=1"),  [.ident("x"), .percentAssign, .int(1)])
        XCTAssertEqual(lex("x**=1"), [.ident("x"), .starStarAssign, .int(1)])
        XCTAssertEqual(lex("x<<=1"), [.ident("x"), .shiftLeftAssign, .int(1)])
        XCTAssertEqual(lex("x>>=1"), [.ident("x"), .shiftRightAssign, .int(1)])
        XCTAssertEqual(lex("x&=1"),  [.ident("x"), .ampAssign, .int(1)])
        XCTAssertEqual(lex("x^=1"),  [.ident("x"), .caretAssign, .int(1)])
        XCTAssertEqual(lex("x|=1"),  [.ident("x"), .barAssign, .int(1)])
    }

    func testIncrementDecrement() {
        XCTAssertEqual(lex("x++"), [.ident("x"), .plusPlus])
        XCTAssertEqual(lex("x--"), [.ident("x"), .minusMinus])
        XCTAssertEqual(lex("++x"), [.plusPlus, .ident("x")])
        XCTAssertEqual(lex("--x"), [.minusMinus, .ident("x")])
    }

    // MARK: Grouping, ternary, comma

    func testPunctuation() {
        XCTAssertEqual(lex("(1)"), [.lParen, .int(1), .rParen])
        XCTAssertEqual(lex("a ? b : c"),
                       [.ident("a"), .question, .ident("b"), .colon, .ident("c")])
        XCTAssertEqual(lex("a, b"), [.ident("a"), .comma, .ident("b")])
    }

    // MARK: Whitespace

    func testIgnoresWhitespace() {
        XCTAssertEqual(lex("  1  +  2  "), [.int(1), .plus, .int(2)])
        XCTAssertEqual(lex("\t1\n+\t2\n"),  [.int(1), .plus, .int(2)])
    }

    // MARK: Errors

    func testUnexpectedCharacter() {
        XCTAssertThrowsError(try ArithLexer.tokenize("1 @ 2")) { err in
            XCTAssertTrue(err is ArithError, "\(err)")
        }
    }
}
