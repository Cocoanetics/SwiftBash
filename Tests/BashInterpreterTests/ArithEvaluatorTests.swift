import XCTest
@testable import BashInterpreter

final class ArithEvaluatorTests: XCTestCase {

    /// Helper backing a simple in-memory variable store.
    final class Store {
        var vars: [String: String] = [:]
        init(_ initial: [String: String] = [:]) { self.vars = initial }
    }

    private func eval(_ s: String, store: Store = Store()) throws -> Int64 {
        try Arithmetic.evaluate(
            s,
            get: { store.vars[$0] },
            set: { store.vars[$0] = String($1) }
        )
    }

    // MARK: Basic arithmetic

    func testLiteral() async throws { XCTAssertEqual(try eval("42"), 42) }
    func testAdd()        throws { XCTAssertEqual(try eval("1 + 2"), 3) }
    func testSub()        throws { XCTAssertEqual(try eval("10 - 3"), 7) }
    func testMul()        throws { XCTAssertEqual(try eval("4 * 5"), 20) }
    func testDiv()        throws { XCTAssertEqual(try eval("20 / 4"), 5) }
    func testIntegerDiv() async throws { XCTAssertEqual(try eval("7 / 2"), 3) }
    func testMod()        throws { XCTAssertEqual(try eval("17 % 5"), 2) }

    func testDivByZeroThrows() async {
        XCTAssertThrowsError(try eval("1 / 0")) { XCTAssertEqual($0 as? ArithError, .divisionByZero) }
    }
    func testModByZeroThrows() async {
        XCTAssertThrowsError(try eval("1 % 0")) { XCTAssertEqual($0 as? ArithError, .moduloByZero) }
    }

    // MARK: Unary

    func testUnaryMinus() async throws { XCTAssertEqual(try eval("-5"),    -5) }
    func testUnaryPlus()  throws { XCTAssertEqual(try eval("+5"),     5) }
    func testDoubleNegation()    throws { XCTAssertEqual(try eval("- -5"),  5) }
    func testLogicalNotZero()    throws { XCTAssertEqual(try eval("!0"),    1) }
    func testLogicalNotNonZero() async throws { XCTAssertEqual(try eval("!5"),    0) }
    func testBitwiseNot()        throws { XCTAssertEqual(try eval("~0"),   -1) }

    // MARK: Precedence

    func testMulBindsTighterThanAdd() async throws {
        XCTAssertEqual(try eval("1 + 2 * 3"), 7)
    }
    func testParensOverride() async throws {
        XCTAssertEqual(try eval("(1 + 2) * 3"), 9)
    }
    func testComplexExpression() async throws {
        XCTAssertEqual(try eval("1 + 2 * 3 - 4 / 2"), 5) // 1 + 6 - 2
    }

    // MARK: Power

    func testPow() async throws { XCTAssertEqual(try eval("2 ** 10"), 1024) }
    func testPowRightAssoc() async throws {
        // 2 ** 3 ** 2 = 2 ** 9 = 512
        XCTAssertEqual(try eval("2 ** 3 ** 2"), 512)
    }
    func testUnaryMinusLooserThanPow() async throws {
        // Bash: -2 ** 2 == -(2**2) == -4
        XCTAssertEqual(try eval("-2 ** 2"), -4)
    }
    func testNegativeExponentThrows() async {
        XCTAssertThrowsError(try eval("2 ** -1"))
    }

    // MARK: Comparison

    func testComparisonReturnsZeroOrOne() async throws {
        XCTAssertEqual(try eval("5 > 3"), 1)
        XCTAssertEqual(try eval("5 < 3"), 0)
        XCTAssertEqual(try eval("5 <= 5"), 1)
        XCTAssertEqual(try eval("5 >= 6"), 0)
        XCTAssertEqual(try eval("5 == 5"), 1)
        XCTAssertEqual(try eval("5 != 5"), 0)
    }

    // MARK: Logical with short-circuit

    func testLogicalAndTruthTable() async throws {
        XCTAssertEqual(try eval("1 && 1"), 1)
        XCTAssertEqual(try eval("1 && 0"), 0)
        XCTAssertEqual(try eval("0 && 1"), 0)
        XCTAssertEqual(try eval("0 && 0"), 0)
    }

    func testLogicalOrTruthTable() async throws {
        XCTAssertEqual(try eval("1 || 1"), 1)
        XCTAssertEqual(try eval("1 || 0"), 1)
        XCTAssertEqual(try eval("0 || 1"), 1)
        XCTAssertEqual(try eval("0 || 0"), 0)
    }

    func testAndShortCircuitsOnFalse() async throws {
        let store = Store()
        // The RHS assignment must not execute — x stays unset.
        XCTAssertEqual(try eval("0 && (x = 5)", store: store), 0)
        XCTAssertNil(store.vars["x"])
    }

    func testOrShortCircuitsOnTrue() async throws {
        let store = Store()
        XCTAssertEqual(try eval("1 || (x = 5)", store: store), 1)
        XCTAssertNil(store.vars["x"])
    }

    // MARK: Bitwise

    func testBitwiseOps() async throws {
        XCTAssertEqual(try eval("12 & 10"), 8)
        XCTAssertEqual(try eval("12 | 10"), 14)
        XCTAssertEqual(try eval("12 ^ 10"), 6)
        XCTAssertEqual(try eval("1 << 4"), 16)
        XCTAssertEqual(try eval("256 >> 3"), 32)
    }

    // MARK: Ternary

    func testTernaryTrue()  throws { XCTAssertEqual(try eval("1 ? 10 : 20"), 10) }
    func testTernaryFalse() async throws { XCTAssertEqual(try eval("0 ? 10 : 20"), 20) }
    func testTernaryNesting() async throws {
        XCTAssertEqual(try eval("1 ? 2 ? 3 : 4 : 5"), 3)
    }
    func testTernaryShortCircuits() async throws {
        let store = Store()
        _ = try eval("1 ? 0 : (x = 5)", store: store)
        XCTAssertNil(store.vars["x"], "else branch should not run")
    }

    // MARK: Assignment / inc-dec

    func testPlainAssignment() async throws {
        let store = Store()
        XCTAssertEqual(try eval("x = 5", store: store), 5)
        XCTAssertEqual(store.vars["x"], "5")
    }

    func testChainedAssignment() async throws {
        let store = Store()
        XCTAssertEqual(try eval("a = b = 10", store: store), 10)
        XCTAssertEqual(store.vars["a"], "10")
        XCTAssertEqual(store.vars["b"], "10")
    }

    func testCompoundAssignments() async throws {
        let store = Store(["x": "10"])
        XCTAssertEqual(try eval("x += 5", store: store), 15)
        XCTAssertEqual(store.vars["x"], "15")

        _ = try eval("x -= 3", store: store)
        XCTAssertEqual(store.vars["x"], "12")

        _ = try eval("x *= 2", store: store)
        XCTAssertEqual(store.vars["x"], "24")

        _ = try eval("x /= 4", store: store)
        XCTAssertEqual(store.vars["x"], "6")

        _ = try eval("x %= 4", store: store)
        XCTAssertEqual(store.vars["x"], "2")

        _ = try eval("x **= 3", store: store)
        XCTAssertEqual(store.vars["x"], "8")

        _ = try eval("x <<= 1", store: store)
        XCTAssertEqual(store.vars["x"], "16")

        _ = try eval("x >>= 2", store: store)
        XCTAssertEqual(store.vars["x"], "4")
    }

    func testBitwiseCompoundAssignments() async throws {
        let store = Store(["x": "12"])
        _ = try eval("x &= 10", store: store)
        XCTAssertEqual(store.vars["x"], "8")
        _ = try eval("x |= 3", store: store)
        XCTAssertEqual(store.vars["x"], "11")
        _ = try eval("x ^= 5", store: store)
        XCTAssertEqual(store.vars["x"], "14")
    }

    func testPostfixIncrementReturnsOldValue() async throws {
        let store = Store(["x": "5"])
        XCTAssertEqual(try eval("x++", store: store), 5)
        XCTAssertEqual(store.vars["x"], "6")
    }

    func testPrefixIncrementReturnsNewValue() async throws {
        let store = Store(["x": "5"])
        XCTAssertEqual(try eval("++x", store: store), 6)
        XCTAssertEqual(store.vars["x"], "6")
    }

    func testPostfixDecrement() async throws {
        let store = Store(["x": "5"])
        XCTAssertEqual(try eval("x--", store: store), 5)
        XCTAssertEqual(store.vars["x"], "4")
    }

    func testPrefixDecrement() async throws {
        let store = Store(["x": "5"])
        XCTAssertEqual(try eval("--x", store: store), 4)
        XCTAssertEqual(store.vars["x"], "4")
    }

    // MARK: Variables

    func testUnsetVariableIsZero() async throws {
        XCTAssertEqual(try eval("x + 1"), 1)
    }

    func testReadVariable() async throws {
        let store = Store(["x": "42"])
        XCTAssertEqual(try eval("x", store: store), 42)
    }

    func testVariableHexValue() async throws {
        let store = Store(["x": "0xff"])
        XCTAssertEqual(try eval("x", store: store), 255)
    }

    func testVariableOctalValue() async throws {
        let store = Store(["x": "010"])
        XCTAssertEqual(try eval("x", store: store), 8)
    }

    func testRecursiveVariableEvaluation() async throws {
        let store = Store(["y": "1", "x": "y"])
        XCTAssertEqual(try eval("x", store: store), 1)
    }

    func testRecursiveVariableWithExpression() async throws {
        let store = Store(["y": "z + 1", "z": "5", "x": "y"])
        XCTAssertEqual(try eval("x * 2", store: store), 12) // (5+1) * 2
    }

    func testRecursionLimit() async {
        // Circular reference: x → y → x …
        let store = Store(["x": "y", "y": "x"])
        XCTAssertThrowsError(try eval("x", store: store)) { err in
            XCTAssertEqual(err as? ArithError, .recursionLimit)
        }
    }

    // MARK: Comma / sequence

    func testCommaReturnsLast() async throws {
        XCTAssertEqual(try eval("1, 2, 3"), 3)
    }

    func testCommaEvaluatesSideEffects() async throws {
        let store = Store()
        XCTAssertEqual(try eval("a = 1, b = 2, a + b", store: store), 3)
        XCTAssertEqual(store.vars["a"], "1")
        XCTAssertEqual(store.vars["b"], "2")
    }

    // MARK: Wrapping overflow behaviour

    func testSignedOverflowWraps() async throws {
        // Int64.max + 1 wraps to Int64.min.
        let store = Store(["m": "\(Int64.max)"])
        XCTAssertEqual(try eval("m + 1", store: store), Int64.min)
    }
}
