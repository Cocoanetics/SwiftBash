import XCTest
@testable import BashInterpreter

/// Parser tests verify structure — they don't evaluate; they examine the
/// shape of the returned `ArithExpr`. For many precedence checks, just
/// re-evaluating via `Arithmetic.evaluate` is clearer; those live in
/// `ArithEvaluatorTests`. Here we pin down AST shapes that would
/// regress silently otherwise.
final class ArithParserTests: XCTestCase {

    private func parse(_ s: String,
                       file: StaticString = #filePath,
                       line: UInt = #line) -> ArithExpr {
        do {
            return try Arithmetic.parse(s)
        } catch {
            XCTFail("parse failed: \(error)", file: file, line: line)
            return .int(0)
        }
    }

    // MARK: Leaves

    func testIntLiteral() async {
        XCTAssertEqual(parse("42"), .int(42))
    }

    func testVariable() async {
        XCTAssertEqual(parse("x"), .variable("x"))
    }

    // MARK: Unary prefix

    func testUnaryMinus() async {
        XCTAssertEqual(parse("-1"), .unary(.minus, .int(1)))
    }

    func testUnaryNot() async {
        XCTAssertEqual(parse("!x"), .unary(.logicalNot, .variable("x")))
    }

    func testBitwiseNot() async {
        XCTAssertEqual(parse("~x"), .unary(.bitwiseNot, .variable("x")))
    }

    func testPrefixIncrement() async {
        XCTAssertEqual(parse("++x"), .prefix(.inc, name: "x"))
        XCTAssertEqual(parse("--x"), .prefix(.dec, name: "x"))
    }

    func testPostfixIncrement() async {
        XCTAssertEqual(parse("x++"), .postfix(.inc, name: "x"))
        XCTAssertEqual(parse("x--"), .postfix(.dec, name: "x"))
    }

    func testPrefixOnNonVariableThrows() async {
        XCTAssertThrowsError(try Arithmetic.parse("++5"))
        XCTAssertThrowsError(try Arithmetic.parse("5++"))
    }

    // MARK: Binary precedence

    func testMulBindsTighterThanAdd() async {
        // 1 + 2 * 3 → 1 + (2 * 3)
        XCTAssertEqual(
            parse("1 + 2 * 3"),
            .binary(.add, .int(1), .binary(.mul, .int(2), .int(3)))
        )
    }

    func testLeftAssociativityOfAddition() async {
        // 1 + 2 + 3 → (1 + 2) + 3
        XCTAssertEqual(
            parse("1 + 2 + 3"),
            .binary(.add, .binary(.add, .int(1), .int(2)), .int(3))
        )
    }

    func testRightAssociativityOfPow() async {
        // 2 ** 3 ** 2 → 2 ** (3 ** 2)
        XCTAssertEqual(
            parse("2 ** 3 ** 2"),
            .binary(.pow, .int(2), .binary(.pow, .int(3), .int(2)))
        )
    }

    func testUnaryBindsLooserThanPow() async {
        // Bash: -2 ** 2 is -(2**2) = -4.
        XCTAssertEqual(
            parse("-2 ** 2"),
            .unary(.minus, .binary(.pow, .int(2), .int(2)))
        )
    }

    func testUnaryBindsTighterThanAdd() async {
        // -2 + 3 → (-2) + 3
        XCTAssertEqual(
            parse("-2 + 3"),
            .binary(.add, .unary(.minus, .int(2)), .int(3))
        )
    }

    func testComparisonAboveLogical() async {
        // a < b && c < d → (a < b) && (c < d)
        XCTAssertEqual(
            parse("a < b && c < d"),
            .binary(.logicalAnd,
                    .binary(.lt, .variable("a"), .variable("b")),
                    .binary(.lt, .variable("c"), .variable("d")))
        )
    }

    func testParensOverrideDefaultPrecedence() async {
        // (1 + 2) * 3 → multiplication of a sum.
        XCTAssertEqual(
            parse("(1 + 2) * 3"),
            .binary(.mul, .binary(.add, .int(1), .int(2)), .int(3))
        )
    }

    // MARK: Ternary

    func testTernaryIsRightAssociative() async {
        // a ? b : c ? d : e  →  a ? b : (c ? d : e)
        XCTAssertEqual(
            parse("a ? b : c ? d : e"),
            .ternary(
                .variable("a"),
                .variable("b"),
                .ternary(.variable("c"), .variable("d"), .variable("e"))
            )
        )
    }

    func testMissingColonThrows() async {
        XCTAssertThrowsError(try Arithmetic.parse("a ? b"))
    }

    // MARK: Assignment

    func testAssignmentIsRightAssociative() async {
        // a = b = 5 → a = (b = 5)
        XCTAssertEqual(
            parse("a = b = 5"),
            .assign(name: "a", op: .set,
                    rhs: .assign(name: "b", op: .set, rhs: .int(5)))
        )
    }

    func testCompoundAssignmentsMapToPairedBinary() async {
        XCTAssertEqual(
            parse("x += 1"),
            .assign(name: "x", op: .addSet, rhs: .int(1))
        )
        XCTAssertEqual(
            parse("x ^= 3"),
            .assign(name: "x", op: .xorSet, rhs: .int(3))
        )
    }

    func testAssignmentToNonVariableThrows() async {
        XCTAssertThrowsError(try Arithmetic.parse("(a + b) = 5"))
    }

    // MARK: Comma (sequence)

    func testCommaSequenceFlattens() async {
        XCTAssertEqual(parse("1, 2, 3"),
                       .sequence([.int(1), .int(2), .int(3)]))
    }

    // MARK: Error cases

    func testEmptyExpressionThrows() async {
        XCTAssertThrowsError(try Arithmetic.parse(""))
    }

    func testUnbalancedParenThrows() async {
        XCTAssertThrowsError(try Arithmetic.parse("(1 + 2"))
    }

    func testDanglingOperatorThrows() async {
        XCTAssertThrowsError(try Arithmetic.parse("1 +"))
    }

    func testTrailingJunkThrows() async {
        XCTAssertThrowsError(try Arithmetic.parse("1 2"))
    }
}
