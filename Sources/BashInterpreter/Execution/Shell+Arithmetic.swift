import Foundation
import BashSyntax

/// An arithmetic expression assigned a read-only variable
/// (`$((UID=3))`).
struct ReadonlyArithmeticAssignment: Error {
    let name: String
}

extension Shell {

    /// Evaluate an arithmetic expression body against this shell's
    /// environment, returning the numeric result.
    ///
    /// Bash applies the inside-double-quotes substitution rules to the
    /// expression *before* arithmetic parsing, so things like
    /// `${10}`, `$(cmd)`, `$((nested))`, `${var:-N}`, and backticks
    /// all work inside `$((…))`. We pre-pass through
    /// ``expandHeredocBody(_:)`` (which has those rules), then hand
    /// the resulting string to the arithmetic lexer.
    ///
    /// Unset variables evaluate as 0. Assignments inside the expression
    /// are written back to `environment.variables` as decimal strings.
    ///
    /// Assigning a read-only variable prints bash's diagnostic and drops
    /// the rest of the top-level command, as `$((UID=3))` does in bash.
    func evaluateArithmetic(_ expression: String) async throws -> Int64 {
        do {
            return try await evaluateArithmeticExpression(expression)
        } catch let error as ReadonlyArithmeticAssignment {
            _ = refuseReadonlyAssignment(error.name)
            throw DiscardCommand()
        }
    }

    /// `((…))` and `let`: like ``evaluateArithmetic(_:)``, but assigning
    /// a read-only variable only fails the command. `nil` then.
    func evaluateArithmeticCommand(_ expression: String) async throws -> Int64? {
        do {
            return try await evaluateArithmeticExpression(expression)
        } catch let error as ReadonlyArithmeticAssignment {
            _ = refuseReadonlyAssignment(error.name)
            return nil
        }
    }

    private func evaluateArithmeticExpression(
        _ expression: String
    ) async throws -> Int64 {
        let preExpanded = try await expandHeredocBody(expression)
        return try Arithmetic.evaluate(
            preExpanded,
            get: { [weak self, environment, positionalParameters] name in
                // Digit-only names are positional parameters: `$1`,
                // `$2`, … The lexer emits these from `$<digits>`.
                if let number = Int(name), number >= 1, !name.isEmpty,
                   name.allSatisfy(\.isNumber) {
                    let idx = number - 1
                    return idx < positionalParameters.count
                        ? positionalParameters[idx]
                        : nil
                }
                // `((RANDOM % 6))` reads a fresh value, as in bash.
                if let dynamic = self?.dynamicVariable(name) {
                    return dynamic
                }
                return environment.variables[name]
            },
            set: { [weak self] name, value in
                if self?.isReadonlyVariable(name) == true {
                    throw ReadonlyArithmeticAssignment(name: name)
                }
                self?.environment.variables[name] = String(value)
            },
            getIndexed: { [environment] name, index in
                // Associative arrays index by stringified key; integer
                // indices on those happen to round-trip (`m[0]` reads
                // key "0"). Bash itself follows the same convention
                // when an associative array slot is read inside `((…))`.
                if let dict = environment.associativeArrays[name] {
                    return dict[String(index)]
                }
                if let arr = environment.arrays[name] {
                    return arr[Int(index)]
                }
                // Mimic bash: a bare scalar `name` is treated as the
                // sole element at index 0; reads at other indices on a
                // scalar yield the empty string (→ 0).
                if index == 0 {
                    return environment.variables[name]
                }
                return nil
            },
            setIndexed: { [weak self] name, index, value in
                try self?.setArithmeticElement(name, index: index, to: value)
            }
        )
    }

    /// `arr[index] = value` from an arithmetic expression.
    private func setArithmeticElement(_ name: String, index: Int64,
                                      to value: Int64) throws {
        if isReadonlyVariable(name) {
            throw ReadonlyArithmeticAssignment(name: name)
        }
        let stringValue = String(value)
        if environment.associativeArrays[name] != nil {
            environment.associativeArrays[name]?[String(index)] = stringValue
            return
        }
        // Promote a scalar to an array if needed — bash does the same
        // when you assign `a[2]=x` to a name that was previously a
        // scalar `a=foo`.
        var arr = environment.arrays[name] ?? BashArray()
        arr[Int(index)] = stringValue
        environment.arrays[name] = arr
        environment.variables.removeValue(forKey: name)
    }

    /// Run a standalone `((expression))` command. Exit status follows
    /// bash's inverted convention: non-zero result → `.success`,
    /// zero result → `.failure`.
    func runArithmeticCommand(_ expression: String) async throws -> ExitStatus {
        guard let value = try await evaluateArithmeticCommand(expression)
        else { return .failure }
        return value != 0 ? .success : .failure
    }
}
