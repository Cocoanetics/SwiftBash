import Foundation
import BashSyntax

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
    func evaluateArithmetic(_ expression: String) async throws -> Int64 {
        let preExpanded = try await expandHeredocBody(expression)
        return try Arithmetic.evaluate(
            preExpanded,
            get: { [environment, positionalParameters] name in
                // Digit-only names are positional parameters: `$1`,
                // `$2`, … The lexer emits these from `$<digits>`.
                if let number = Int(name), number >= 1, !name.isEmpty,
                   name.allSatisfy(\.isNumber) {
                    let idx = number - 1
                    return idx < positionalParameters.count
                        ? positionalParameters[idx]
                        : nil
                }
                return environment.variables[name]
            },
            set: { [weak self] name, value in
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
                guard let self = self else { return }
                let stringValue = String(value)
                if self.environment.associativeArrays[name] != nil {
                    self.environment.associativeArrays[name]?[
                        String(index)] = stringValue
                    return
                }
                // Promote a scalar to an array if needed — bash does
                // the same when you assign `a[2]=x` to a name that
                // was previously a scalar `a=foo`.
                var arr = self.environment.arrays[name] ?? BashArray()
                arr[Int(index)] = stringValue
                self.environment.arrays[name] = arr
                self.environment.variables.removeValue(forKey: name)
            }
        )
    }

    /// Run a standalone `((expression))` command. Exit status follows
    /// bash's inverted convention: non-zero result → `.success`,
    /// zero result → `.failure`.
    func runArithmeticCommand(_ expression: String) async throws -> ExitStatus {
        let value = try await evaluateArithmetic(expression)
        return value != 0 ? .success : .failure
    }
}
