import Foundation

/// Evaluate bash arithmetic expressions into 64-bit signed integers.
///
/// ```swift
/// var env: [String: String] = ["x": "5"]
/// let result = try Arithmetic.evaluate(
///     "x * 2 + 1",
///     get: { env[$0] },
///     set: { env[$0] = String($1) }
/// )
/// // => 11
/// ```
///
/// The evaluator mirrors bash's semantics: integer-only 64-bit arithmetic
/// (wrap on overflow), unset variables read as 0, non-numeric variable
/// values are recursively re-evaluated as expressions, `&&` / `||` and
/// `? :` short-circuit, and the exit-status convention for `((…))` is
/// inverted (0 is "false", non-zero is "true").
public enum Arithmetic {

    /// Highest allowed depth of recursive variable resolution. Guards
    /// against loops like `x=y; y=x`.
    public static let maxRecursionDepth = 64

    /// Evaluate a bash arithmetic expression.
    ///
    /// - Parameters:
    ///   - source:     The raw expression body (no outer `((` / `))`).
    ///   - get:        Reads the raw string value of a shell variable;
    ///                 `nil` if unset. Unset variables evaluate as 0.
    ///   - set:        Writes back the new integer value of a variable
    ///                 (called once per `=`, `++`, `--`, compound assign).
    ///   - getIndexed: Reads `arr[index]` from an array variable. `nil`
    ///                 → use the bare-name fallback (which yields 0 for
    ///                 every index, matching bash for unset arrays).
    ///   - setIndexed: Writes `arr[index] = value`. `nil` → indexed
    ///                 assignment throws ``ArithError/invalidAssignmentTarget``.
    /// - Returns: The final `Int64` value of the expression.
    public static func evaluate(
        _ source: String,
        get: @escaping (String) -> String?,
        set: @escaping (String, Int64) -> Void,
        getIndexed: ((String, Int64) -> String?)? = nil,
        setIndexed: ((String, Int64, Int64) -> Void)? = nil
    ) throws -> Int64 {
        let expr = try ArithParser().parse(source)
        let evaluator = Evaluator(
            get: get, set: set,
            getIndexed: getIndexed, setIndexed: setIndexed)
        return try evaluator.eval(expr, depth: 0)
    }

    /// Parse an expression without evaluating — useful for tests.
    public static func parse(_ source: String) throws -> ArithExpr {
        try ArithParser().parse(source)
    }

    // MARK: Evaluator

    struct Evaluator {
        let get: (String) -> String?
        let set: (String, Int64) -> Void
        let getIndexed: ((String, Int64) -> String?)?
        let setIndexed: ((String, Int64, Int64) -> Void)?

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        func eval(_ expr: ArithExpr, depth: Int) throws -> Int64 {
            switch expr {
            case .int(let num):
                return num

            case .variable(let name):
                return try resolveVariable(name, depth: depth)

            case .arrayIndex(let name, let indexExpr):
                let idx = try eval(indexExpr, depth: depth)
                return try resolveIndexed(name: name, index: idx, depth: depth)

            case .unary(let unaryOp, let operand):
                let value = try eval(operand, depth: depth)
                switch unaryOp {
                case .plus:       return value
                case .minus:      return 0 &- value
                case .logicalNot: return value == 0 ? 1 : 0
                case .bitwiseNot: return ~value
                }

            case .prefix(let incOp, let name):
                let old = try resolveVariable(name, depth: depth)
                let new = (incOp == .inc) ? old &+ 1 : old &- 1
                set(name, new)
                return new

            case .postfix(let incOp, let name):
                let old = try resolveVariable(name, depth: depth)
                let new = (incOp == .inc) ? old &+ 1 : old &- 1
                set(name, new)
                return old

            case .prefixIndexed(let incOp, let name, let indexExpr):
                let idx = try eval(indexExpr, depth: depth)
                let old = try resolveIndexed(name: name, index: idx, depth: depth)
                let new = (incOp == .inc) ? old &+ 1 : old &- 1
                guard let setIndexed = setIndexed else {
                    throw ArithError.invalidAssignmentTarget
                }
                setIndexed(name, idx, new)
                return new

            case .postfixIndexed(let incOp, let name, let indexExpr):
                let idx = try eval(indexExpr, depth: depth)
                let old = try resolveIndexed(name: name, index: idx, depth: depth)
                let new = (incOp == .inc) ? old &+ 1 : old &- 1
                guard let setIndexed = setIndexed else {
                    throw ArithError.invalidAssignmentTarget
                }
                setIndexed(name, idx, new)
                return old

            case .binary(let binOp, let lhs, let rhs):
                return try applyBinary(binOp, lhs: lhs, rhs: rhs, depth: depth)

            case .ternary(let cond, let thenExpr, let elseExpr):
                let condVal = try eval(cond, depth: depth)
                return try eval(condVal != 0 ? thenExpr : elseExpr, depth: depth)

            case .assign(let name, let assignOp, let rhs):
                let rhsVal = try eval(rhs, depth: depth)
                let newValue: Int64
                if let binOp = assignOp.pairedBinary {
                    let current = try resolveVariable(name, depth: depth)
                    newValue = try applyBinary(binOp,
                                               leftValue: current,
                                               rightValue: rhsVal)
                } else {
                    newValue = rhsVal
                }
                set(name, newValue)
                return newValue

            case .assignIndex(let name, let indexExpr, let assignOp, let rhs):
                guard let setIndexed = setIndexed else {
                    throw ArithError.invalidAssignmentTarget
                }
                // Evaluate the index *before* the rhs — bash's
                // left-to-right rule. Important when the rhs has side
                // effects: `arr[i++] = ++j` reads i once for the slot.
                let idx = try eval(indexExpr, depth: depth)
                let rhsVal = try eval(rhs, depth: depth)
                let newValue: Int64
                if let binOp = assignOp.pairedBinary {
                    let current = try resolveIndexed(
                        name: name, index: idx, depth: depth)
                    newValue = try applyBinary(binOp,
                                               leftValue: current,
                                               rightValue: rhsVal)
                } else {
                    newValue = rhsVal
                }
                setIndexed(name, idx, newValue)
                return newValue

            case .sequence(let parts):
                var last: Int64 = 0
                for part in parts {
                    last = try eval(part, depth: depth)
                }
                return last
            }
        }

        // MARK: Binary ops

        func applyBinary(_ binOp: ArithExpr.BinaryOp,
                         lhs: ArithExpr, rhs: ArithExpr,
                         depth: Int) throws -> Int64 {
            // Short-circuit logical ops without evaluating the RHS when the
            // result is already determined.
            if binOp == .logicalAnd {
                let lhsVal = try eval(lhs, depth: depth)
                if lhsVal == 0 { return 0 }
                let rhsVal = try eval(rhs, depth: depth)
                return rhsVal != 0 ? 1 : 0
            }
            if binOp == .logicalOr {
                let lhsVal = try eval(lhs, depth: depth)
                if lhsVal != 0 { return 1 }
                let rhsVal = try eval(rhs, depth: depth)
                return rhsVal != 0 ? 1 : 0
            }

            let lhsVal = try eval(lhs, depth: depth)
            let rhsVal = try eval(rhs, depth: depth)
            return try applyBinary(binOp, leftValue: lhsVal, rightValue: rhsVal)
        }

        // swiftlint:disable:next cyclomatic_complexity
        func applyBinary(_ binOp: ArithExpr.BinaryOp,
                         leftValue lhs: Int64, rightValue rhs: Int64) throws -> Int64 {
            switch binOp {
            case .add:        return lhs &+ rhs
            case .sub:        return lhs &- rhs
            case .mul:        return lhs &* rhs
            case .div:
                if rhs == 0 { throw ArithError.divisionByZero }
                return lhs / rhs
            case .mod:
                if rhs == 0 { throw ArithError.moduloByZero }
                return lhs % rhs
            case .pow:
                if rhs < 0 { throw ArithError.negativeExponent(rhs) }
                return integerPower(base: lhs, exponent: rhs)
            case .shl:
                return lhs &<< (rhs & 63)
            case .shr:
                return lhs &>> (rhs & 63)
            case .bitAnd:     return lhs & rhs
            case .bitOr:      return lhs | rhs
            case .bitXor:     return lhs ^ rhs
            case .lt:         return lhs <  rhs ? 1 : 0
            case .gt:         return lhs >  rhs ? 1 : 0
            case .le:         return lhs <= rhs ? 1 : 0
            case .ge:         return lhs >= rhs ? 1 : 0
            case .eq:         return lhs == rhs ? 1 : 0
            case .neq:        return lhs != rhs ? 1 : 0
            case .logicalAnd: return (lhs != 0 && rhs != 0) ? 1 : 0
            case .logicalOr:  return (lhs != 0 || rhs != 0) ? 1 : 0
            }
        }

        // MARK: Variable resolution

        /// Resolve `arr[index]` to an Int64. If the host didn't supply
        /// a `getIndexed` closure, indexing falls back to bare-name
        /// lookup of `name` — which yields 0 for arrays per bash's
        /// convention (a bare reference returns index 0; for a totally
        /// unset name we still get 0). Non-numeric string contents go
        /// through the same recursive-evaluation path as scalars.
        func resolveIndexed(name: String, index: Int64,
                            depth: Int) throws -> Int64 {
            guard depth < Arithmetic.maxRecursionDepth else {
                throw ArithError.recursionLimit
            }
            let raw: String?
            if let getIndexed = getIndexed {
                raw = getIndexed(name, index)
            } else {
                // Fallback: index 0 of a bare array reads the same as
                // a scalar `name`; any other index reads as 0.
                raw = (index == 0) ? get(name) : nil
            }
            guard let value = raw, !value.isEmpty else { return 0 }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if let num = parseIntLiteral(trimmed) { return num }
            let subExpr = try ArithParser().parse(trimmed)
            return try eval(subExpr, depth: depth + 1)
        }

        /// Resolve a variable name to an Int64. Unset variables evaluate
        /// as 0. Non-numeric string values are recursively parsed and
        /// evaluated as arithmetic expressions — matching bash. Infinite
        /// recursion (e.g. `x=y; y=x`) is caught via `maxRecursionDepth`.
        func resolveVariable(_ name: String, depth: Int) throws -> Int64 {
            guard depth < Arithmetic.maxRecursionDepth else {
                throw ArithError.recursionLimit
            }
            guard let raw = get(name), !raw.isEmpty else { return 0 }

            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Direct integer literal in a common base.
            if let num = parseIntLiteral(trimmed) {
                return num
            }

            // Otherwise treat the raw string as an arithmetic expression.
            let subExpr = try ArithParser().parse(trimmed)
            return try eval(subExpr, depth: depth + 1)
        }

        // Fast path: `"123"`, `"-5"`, `"0x1F"`, `"0777"`, `"2#1010"`.
        // swiftlint:disable:next cyclomatic_complexity
        private func parseIntLiteral(_ str: String) -> Int64? {
            var chars = Substring(str)
            var sign: Int64 = 1
            if chars.first == "-" {
                sign = -1; chars = chars.dropFirst()
            } else if chars.first == "+" {
                chars = chars.dropFirst()
            }
            if chars.isEmpty { return nil }

            // Hex
            if chars.hasPrefix("0x") || chars.hasPrefix("0X") {
                let digits = chars.dropFirst(2)
                guard !digits.isEmpty,
                      let num = UInt64(digits, radix: 16) else { return nil }
                return Int64(bitPattern: num) * sign
            }
            // Base#N
            if let hash = chars.firstIndex(of: "#"),
               let base = Int(chars[..<hash]),
               (2...64) ~= base {
                let digits = chars[chars.index(after: hash)...]
                var value: Int64 = 0
                for char in digits {
                    guard let digitVal = ArithLexer.Lexer.baseDigitValue(char, base: base)
                    else { return nil }
                    value = value &* Int64(base) &+ Int64(digitVal)
                }
                return value * sign
            }
            // Octal
            if chars.count > 1, chars.first == "0",
               chars.allSatisfy({ "01234567".contains($0) }) {
                guard let num = Int64(chars, radix: 8) else { return nil }
                return num * sign
            }
            // Decimal
            guard let num = Int64(chars) else { return nil }
            return num * sign
        }
    }

    /// Integer power with wrap-on-overflow semantics.
    static func integerPower(base: Int64, exponent: Int64) -> Int64 {
        var result: Int64 = 1
        var baseVal = base
        var expVal = exponent
        while expVal > 0 {
            if (expVal & 1) == 1 { result = result &* baseVal }
            expVal >>= 1
            if expVal > 0 { baseVal = baseVal &* baseVal }
        }
        return result
    }
}
