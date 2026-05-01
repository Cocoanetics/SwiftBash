import Testing
@testable import BashInterpreter

/// Parser tests verify structure — they don't evaluate; they examine the
/// shape of the returned `ArithExpr`. For many precedence checks, just
/// re-evaluating via `Arithmetic.evaluate` is clearer; those live in
/// `ArithEvaluatorTests`. Here we pin down AST shapes that would
/// regress silently otherwise.
@Suite(.timeLimit(.minutes(1))) struct ArithParserTests {

    private func parse(_ s: String,
                       sourceLocation: SourceLocation = #_sourceLocation) -> ArithExpr {
        do {
            return try Arithmetic.parse(s)
        } catch {
            Issue.record("parse failed: \(error)", sourceLocation: sourceLocation)
            return .int(0)
        }
    }

    // MARK: Leaves

    @Test func intLiteral() {
        #expect(parse("42") == .int(42))
    }

    @Test func variable() {
        #expect(parse("x") == .variable("x"))
    }

    // MARK: Unary prefix

    @Test func unaryMinus() {
        #expect(parse("-1") == .unary(.minus, .int(1)))
    }

    @Test func unaryNot() {
        #expect(parse("!x") == .unary(.logicalNot, .variable("x")))
    }

    @Test func bitwiseNot() {
        #expect(parse("~x") == .unary(.bitwiseNot, .variable("x")))
    }

    @Test func prefixIncrement() {
        #expect(parse("++x") == .prefix(.inc, name: "x"))
        #expect(parse("--x") == .prefix(.dec, name: "x"))
    }

    @Test func postfixIncrement() {
        #expect(parse("x++") == .postfix(.inc, name: "x"))
        #expect(parse("x--") == .postfix(.dec, name: "x"))
    }

    @Test func prefixOnNonVariableThrows() {
        #expect(throws: (any Error).self) { try Arithmetic.parse("++5") }
        #expect(throws: (any Error).self) { try Arithmetic.parse("5++") }
    }

    // MARK: Binary precedence

    @Test func mulBindsTighterThanAdd() {
        // 1 + 2 * 3 → 1 + (2 * 3)
        #expect(
            parse("1 + 2 * 3") ==
            .binary(.add, .int(1), .binary(.mul, .int(2), .int(3)))
        )
    }

    @Test func leftAssociativityOfAddition() {
        // 1 + 2 + 3 → (1 + 2) + 3
        #expect(
            parse("1 + 2 + 3") ==
            .binary(.add, .binary(.add, .int(1), .int(2)), .int(3))
        )
    }

    @Test func rightAssociativityOfPow() {
        // 2 ** 3 ** 2 → 2 ** (3 ** 2)
        #expect(
            parse("2 ** 3 ** 2") ==
            .binary(.pow, .int(2), .binary(.pow, .int(3), .int(2)))
        )
    }

    @Test func unaryBindsLooserThanPow() {
        // Bash: -2 ** 2 is -(2**2) = -4.
        #expect(
            parse("-2 ** 2") ==
            .unary(.minus, .binary(.pow, .int(2), .int(2)))
        )
    }

    @Test func unaryBindsTighterThanAdd() {
        // -2 + 3 → (-2) + 3
        #expect(
            parse("-2 + 3") ==
            .binary(.add, .unary(.minus, .int(2)), .int(3))
        )
    }

    @Test func comparisonAboveLogical() {
        // a < b && c < d → (a < b) && (c < d)
        #expect(
            parse("a < b && c < d") ==
            .binary(.logicalAnd,
                    .binary(.lt, .variable("a"), .variable("b")),
                    .binary(.lt, .variable("c"), .variable("d")))
        )
    }

    @Test func parensOverrideDefaultPrecedence() {
        // (1 + 2) * 3 → multiplication of a sum.
        #expect(
            parse("(1 + 2) * 3") ==
            .binary(.mul, .binary(.add, .int(1), .int(2)), .int(3))
        )
    }

    // MARK: Ternary

    @Test func ternaryIsRightAssociative() {
        // a ? b : c ? d : e  →  a ? b : (c ? d : e)
        #expect(
            parse("a ? b : c ? d : e") ==
            .ternary(
                .variable("a"),
                .variable("b"),
                .ternary(.variable("c"), .variable("d"), .variable("e"))
            )
        )
    }

    @Test func missingColonThrows() {
        #expect(throws: (any Error).self) { try Arithmetic.parse("a ? b") }
    }

    // MARK: Assignment

    @Test func assignmentIsRightAssociative() {
        // a = b = 5 → a = (b = 5)
        #expect(
            parse("a = b = 5") ==
            .assign(name: "a", op: .set,
                    rhs: .assign(name: "b", op: .set, rhs: .int(5)))
        )
    }

    @Test func compoundAssignmentsMapToPairedBinary() {
        #expect(
            parse("x += 1") ==
            .assign(name: "x", op: .addSet, rhs: .int(1))
        )
        #expect(
            parse("x ^= 3") ==
            .assign(name: "x", op: .xorSet, rhs: .int(3))
        )
    }

    @Test func assignmentToNonVariableThrows() {
        #expect(throws: (any Error).self) { try Arithmetic.parse("(a + b) = 5") }
    }

    // MARK: Comma (sequence)

    @Test func commaSequenceFlattens() {
        #expect(parse("1, 2, 3") == .sequence([.int(1), .int(2), .int(3)]))
    }

    // MARK: Error cases

    @Test func emptyExpressionThrows() {
        #expect(throws: (any Error).self) { try Arithmetic.parse("") }
    }

    @Test func unbalancedParenThrows() {
        #expect(throws: (any Error).self) { try Arithmetic.parse("(1 + 2") }
    }

    @Test func danglingOperatorThrows() {
        #expect(throws: (any Error).self) { try Arithmetic.parse("1 +") }
    }

    @Test func trailingJunkThrows() {
        #expect(throws: (any Error).self) { try Arithmetic.parse("1 2") }
    }
}
