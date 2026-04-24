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
    ///   - source: The raw expression body (no outer `((` / `))`).
    ///   - get:    Reads the raw string value of a shell variable; `nil`
    ///             if unset. Unset variables evaluate as 0.
    ///   - set:    Writes back the new integer value of a variable
    ///             (called once per `=`, `++`, `--`, compound assign).
    /// - Returns: The final `Int64` value of the expression.
    public static func evaluate(
        _ source: String,
        get: @escaping (String) -> String?,
        set: @escaping (String, Int64) -> Void
    ) throws -> Int64 {
        let expr = try ArithParser().parse(source)
        let evaluator = Evaluator(get: get, set: set)
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

        func eval(_ e: ArithExpr, depth: Int) throws -> Int64 {
            switch e {
            case .int(let n):
                return n

            case .variable(let name):
                return try resolveVariable(name, depth: depth)

            case .unary(let op, let operand):
                let v = try eval(operand, depth: depth)
                switch op {
                case .plus:       return v
                case .minus:      return 0 &- v
                case .logicalNot: return v == 0 ? 1 : 0
                case .bitwiseNot: return ~v
                }

            case .prefix(let op, let name):
                let old = try resolveVariable(name, depth: depth)
                let new = (op == .inc) ? old &+ 1 : old &- 1
                set(name, new)
                return new

            case .postfix(let op, let name):
                let old = try resolveVariable(name, depth: depth)
                let new = (op == .inc) ? old &+ 1 : old &- 1
                set(name, new)
                return old

            case .binary(let op, let lhs, let rhs):
                return try applyBinary(op, lhs: lhs, rhs: rhs, depth: depth)

            case .ternary(let cond, let thenExpr, let elseExpr):
                let c = try eval(cond, depth: depth)
                return try eval(c != 0 ? thenExpr : elseExpr, depth: depth)

            case .assign(let name, let op, let rhs):
                let rv = try eval(rhs, depth: depth)
                let newValue: Int64
                if let binOp = op.pairedBinary {
                    let current = try resolveVariable(name, depth: depth)
                    newValue = try applyBinary(binOp,
                                               leftValue: current,
                                               rightValue: rv)
                } else {
                    newValue = rv
                }
                set(name, newValue)
                return newValue

            case .sequence(let parts):
                var last: Int64 = 0
                for p in parts {
                    last = try eval(p, depth: depth)
                }
                return last
            }
        }

        // MARK: Binary ops

        func applyBinary(_ op: ArithExpr.BinaryOp,
                                  lhs: ArithExpr, rhs: ArithExpr,
                                  depth: Int) throws -> Int64 {
            // Short-circuit logical ops without evaluating the RHS when the
            // result is already determined.
            if op == .logicalAnd {
                let l = try eval(lhs, depth: depth)
                if l == 0 { return 0 }
                let r = try eval(rhs, depth: depth)
                return r != 0 ? 1 : 0
            }
            if op == .logicalOr {
                let l = try eval(lhs, depth: depth)
                if l != 0 { return 1 }
                let r = try eval(rhs, depth: depth)
                return r != 0 ? 1 : 0
            }

            let l = try eval(lhs, depth: depth)
            let r = try eval(rhs, depth: depth)
            return try applyBinary(op, leftValue: l, rightValue: r)
        }

        func applyBinary(_ op: ArithExpr.BinaryOp,
                         leftValue l: Int64, rightValue r: Int64) throws -> Int64 {
            switch op {
            case .add:        return l &+ r
            case .sub:        return l &- r
            case .mul:        return l &* r
            case .div:
                if r == 0 { throw ArithError.divisionByZero }
                return l / r
            case .mod:
                if r == 0 { throw ArithError.moduloByZero }
                return l % r
            case .pow:
                if r < 0 { throw ArithError.negativeExponent(r) }
                return integerPower(base: l, exponent: r)
            case .shl:
                return l &<< (r & 63)
            case .shr:
                return l &>> (r & 63)
            case .bitAnd:     return l & r
            case .bitOr:      return l | r
            case .bitXor:     return l ^ r
            case .lt:         return l <  r ? 1 : 0
            case .gt:         return l >  r ? 1 : 0
            case .le:         return l <= r ? 1 : 0
            case .ge:         return l >= r ? 1 : 0
            case .eq:         return l == r ? 1 : 0
            case .neq:        return l != r ? 1 : 0
            case .logicalAnd: return (l != 0 && r != 0) ? 1 : 0
            case .logicalOr:  return (l != 0 || r != 0) ? 1 : 0
            }
        }

        // MARK: Variable resolution

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
            if let n = parseIntLiteral(trimmed) {
                return n
            }

            // Otherwise treat the raw string as an arithmetic expression.
            let subExpr = try ArithParser().parse(trimmed)
            return try eval(subExpr, depth: depth + 1)
        }

        /// Fast path: `"123"`, `"-5"`, `"0x1F"`, `"0777"`, `"2#1010"`.
        private func parseIntLiteral(_ s: String) -> Int64? {
            var chars = Substring(s)
            var sign: Int64 = 1
            if chars.first == "-" { sign = -1; chars = chars.dropFirst() }
            else if chars.first == "+" { chars = chars.dropFirst() }
            if chars.isEmpty { return nil }

            // Hex
            if chars.hasPrefix("0x") || chars.hasPrefix("0X") {
                let digits = chars.dropFirst(2)
                guard !digits.isEmpty,
                      let n = UInt64(digits, radix: 16) else { return nil }
                return Int64(bitPattern: n) * sign
            }
            // Base#N
            if let hash = chars.firstIndex(of: "#"),
               let base = Int(chars[..<hash]),
               (2...64) ~= base
            {
                let digits = chars[chars.index(after: hash)...]
                var value: Int64 = 0
                for c in digits {
                    guard let v = ArithLexer.Lexer.baseDigitValue(c, base: base)
                    else { return nil }
                    value = value &* Int64(base) &+ Int64(v)
                }
                return value * sign
            }
            // Octal
            if chars.count > 1, chars.first == "0",
               chars.allSatisfy({ "01234567".contains($0) })
            {
                guard let n = Int64(chars, radix: 8) else { return nil }
                return n * sign
            }
            // Decimal
            guard let n = Int64(chars) else { return nil }
            return n * sign
        }
    }

    /// Integer power with wrap-on-overflow semantics.
    static func integerPower(base: Int64, exponent: Int64) -> Int64 {
        var result: Int64 = 1
        var b = base
        var e = exponent
        while e > 0 {
            if (e & 1) == 1 { result = result &* b }
            e >>= 1
            if e > 0 { b = b &* b }
        }
        return result
    }
}
