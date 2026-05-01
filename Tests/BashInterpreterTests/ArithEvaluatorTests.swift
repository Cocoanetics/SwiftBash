import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct ArithEvaluatorTests {

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

    @Test func literal()        throws { #expect(try eval("42") == 42) }
    @Test func add()            throws { #expect(try eval("1 + 2") == 3) }
    @Test func sub()            throws { #expect(try eval("10 - 3") == 7) }
    @Test func mul()            throws { #expect(try eval("4 * 5") == 20) }
    @Test func div()            throws { #expect(try eval("20 / 4") == 5) }
    @Test func integerDiv()     throws { #expect(try eval("7 / 2") == 3) }
    @Test func mod()            throws { #expect(try eval("17 % 5") == 2) }

    @Test func divByZeroThrows() {
        let err = #expect(throws: ArithError.self) { try eval("1 / 0") }
        #expect(err == .divisionByZero)
    }
    @Test func modByZeroThrows() {
        let err = #expect(throws: ArithError.self) { try eval("1 % 0") }
        #expect(err == .moduloByZero)
    }

    // MARK: Unary

    @Test func unaryMinus()        throws { #expect(try eval("-5") == -5) }
    @Test func unaryPlus()         throws { #expect(try eval("+5") == 5) }
    @Test func doubleNegation()    throws { #expect(try eval("- -5") == 5) }
    @Test func logicalNotZero()    throws { #expect(try eval("!0") == 1) }
    @Test func logicalNotNonZero() throws { #expect(try eval("!5") == 0) }
    @Test func bitwiseNot()        throws { #expect(try eval("~0") == -1) }

    // MARK: Precedence

    @Test func mulBindsTighterThanAdd() throws {
        #expect(try eval("1 + 2 * 3") == 7)
    }
    @Test func parensOverride() throws {
        #expect(try eval("(1 + 2) * 3") == 9)
    }
    @Test func complexExpression() throws {
        #expect(try eval("1 + 2 * 3 - 4 / 2") == 5) // 1 + 6 - 2
    }

    // MARK: Power

    @Test func pow() throws { #expect(try eval("2 ** 10") == 1024) }
    @Test func powRightAssoc() throws {
        // 2 ** 3 ** 2 = 2 ** 9 = 512
        #expect(try eval("2 ** 3 ** 2") == 512)
    }
    @Test func unaryMinusLooserThanPow() throws {
        // Bash: -2 ** 2 == -(2**2) == -4
        #expect(try eval("-2 ** 2") == -4)
    }
    @Test func negativeExponentThrows() {
        #expect(throws: (any Error).self) { try eval("2 ** -1") }
    }

    // MARK: Comparison

    @Test func comparisonReturnsZeroOrOne() throws {
        #expect(try eval("5 > 3") == 1)
        #expect(try eval("5 < 3") == 0)
        #expect(try eval("5 <= 5") == 1)
        #expect(try eval("5 >= 6") == 0)
        #expect(try eval("5 == 5") == 1)
        #expect(try eval("5 != 5") == 0)
    }

    // MARK: Logical with short-circuit

    @Test func logicalAndTruthTable() throws {
        #expect(try eval("1 && 1") == 1)
        #expect(try eval("1 && 0") == 0)
        #expect(try eval("0 && 1") == 0)
        #expect(try eval("0 && 0") == 0)
    }

    @Test func logicalOrTruthTable() throws {
        #expect(try eval("1 || 1") == 1)
        #expect(try eval("1 || 0") == 1)
        #expect(try eval("0 || 1") == 1)
        #expect(try eval("0 || 0") == 0)
    }

    @Test func andShortCircuitsOnFalse() throws {
        let store = Store()
        // The RHS assignment must not execute — x stays unset.
        #expect(try eval("0 && (x = 5)", store: store) == 0)
        #expect(store.vars["x"] == nil)
    }

    @Test func orShortCircuitsOnTrue() throws {
        let store = Store()
        #expect(try eval("1 || (x = 5)", store: store) == 1)
        #expect(store.vars["x"] == nil)
    }

    // MARK: Bitwise

    @Test func bitwiseOps() throws {
        #expect(try eval("12 & 10") == 8)
        #expect(try eval("12 | 10") == 14)
        #expect(try eval("12 ^ 10") == 6)
        #expect(try eval("1 << 4") == 16)
        #expect(try eval("256 >> 3") == 32)
    }

    // MARK: Ternary

    @Test func ternaryTrue()  throws { #expect(try eval("1 ? 10 : 20") == 10) }
    @Test func ternaryFalse() throws { #expect(try eval("0 ? 10 : 20") == 20) }
    @Test func ternaryNesting() throws {
        #expect(try eval("1 ? 2 ? 3 : 4 : 5") == 3)
    }
    @Test func ternaryShortCircuits() throws {
        let store = Store()
        _ = try eval("1 ? 0 : (x = 5)", store: store)
        #expect(store.vars["x"] == nil, "else branch should not run")
    }

    // MARK: Assignment / inc-dec

    @Test func plainAssignment() throws {
        let store = Store()
        #expect(try eval("x = 5", store: store) == 5)
        #expect(store.vars["x"] == "5")
    }

    @Test func chainedAssignment() throws {
        let store = Store()
        #expect(try eval("a = b = 10", store: store) == 10)
        #expect(store.vars["a"] == "10")
        #expect(store.vars["b"] == "10")
    }

    @Test func compoundAssignments() throws {
        let store = Store(["x": "10"])
        #expect(try eval("x += 5", store: store) == 15)
        #expect(store.vars["x"] == "15")

        _ = try eval("x -= 3", store: store)
        #expect(store.vars["x"] == "12")

        _ = try eval("x *= 2", store: store)
        #expect(store.vars["x"] == "24")

        _ = try eval("x /= 4", store: store)
        #expect(store.vars["x"] == "6")

        _ = try eval("x %= 4", store: store)
        #expect(store.vars["x"] == "2")

        _ = try eval("x **= 3", store: store)
        #expect(store.vars["x"] == "8")

        _ = try eval("x <<= 1", store: store)
        #expect(store.vars["x"] == "16")

        _ = try eval("x >>= 2", store: store)
        #expect(store.vars["x"] == "4")
    }

    @Test func bitwiseCompoundAssignments() throws {
        let store = Store(["x": "12"])
        _ = try eval("x &= 10", store: store)
        #expect(store.vars["x"] == "8")
        _ = try eval("x |= 3", store: store)
        #expect(store.vars["x"] == "11")
        _ = try eval("x ^= 5", store: store)
        #expect(store.vars["x"] == "14")
    }

    @Test func postfixIncrementReturnsOldValue() throws {
        let store = Store(["x": "5"])
        #expect(try eval("x++", store: store) == 5)
        #expect(store.vars["x"] == "6")
    }

    @Test func prefixIncrementReturnsNewValue() throws {
        let store = Store(["x": "5"])
        #expect(try eval("++x", store: store) == 6)
        #expect(store.vars["x"] == "6")
    }

    @Test func postfixDecrement() throws {
        let store = Store(["x": "5"])
        #expect(try eval("x--", store: store) == 5)
        #expect(store.vars["x"] == "4")
    }

    @Test func prefixDecrement() throws {
        let store = Store(["x": "5"])
        #expect(try eval("--x", store: store) == 4)
        #expect(store.vars["x"] == "4")
    }

    // MARK: Variables

    @Test func unsetVariableIsZero() throws {
        #expect(try eval("x + 1") == 1)
    }

    @Test func readVariable() throws {
        let store = Store(["x": "42"])
        #expect(try eval("x", store: store) == 42)
    }

    @Test func variableHexValue() throws {
        let store = Store(["x": "0xff"])
        #expect(try eval("x", store: store) == 255)
    }

    @Test func variableOctalValue() throws {
        let store = Store(["x": "010"])
        #expect(try eval("x", store: store) == 8)
    }

    @Test func recursiveVariableEvaluation() throws {
        let store = Store(["y": "1", "x": "y"])
        #expect(try eval("x", store: store) == 1)
    }

    @Test func recursiveVariableWithExpression() throws {
        let store = Store(["y": "z + 1", "z": "5", "x": "y"])
        #expect(try eval("x * 2", store: store) == 12) // (5+1) * 2
    }

    @Test func recursionLimit() {
        // Circular reference: x → y → x …
        let store = Store(["x": "y", "y": "x"])
        let err = #expect(throws: ArithError.self) { try eval("x", store: store) }
        #expect(err == .recursionLimit)
    }

    // MARK: Comma / sequence

    @Test func commaReturnsLast() throws {
        #expect(try eval("1, 2, 3") == 3)
    }

    @Test func commaEvaluatesSideEffects() throws {
        let store = Store()
        #expect(try eval("a = 1, b = 2, a + b", store: store) == 3)
        #expect(store.vars["a"] == "1")
        #expect(store.vars["b"] == "2")
    }

    // MARK: Wrapping overflow behaviour

    // MARK: Positional parameters in arithmetic (lexer + evaluator)

    @Test func dollarOneInArithmetic() throws {
        let store = Store(["1": "5"])
        // Note: in real usage Shell threads positionalParameters into
        // the get closure; here we simulate by storing under key "1".
        #expect(try eval("$1 + 1", store: store) == 6)
    }

    @Test func dollarMultiDigit() throws {
        let store = Store(["10": "42"])
        #expect(try eval("$10 + 8", store: store) == 50)
    }

    @Test func signedOverflowWraps() throws {
        // Int64.max + 1 wraps to Int64.min.
        let store = Store(["m": "\(Int64.max)"])
        #expect(try eval("m + 1", store: store) == Int64.min)
    }
}
