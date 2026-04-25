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
                if let n = Int(name), n >= 1, !name.isEmpty,
                   name.allSatisfy(\.isNumber)
                {
                    let idx = n - 1
                    return idx < positionalParameters.count
                        ? positionalParameters[idx]
                        : nil
                }
                return environment.variables[name]
            },
            set: { [weak self] name, value in
                self?.environment.variables[name] = String(value)
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
