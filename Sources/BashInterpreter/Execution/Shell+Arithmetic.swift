import Foundation
import BashSyntax

extension Shell {

    /// Evaluate an arithmetic expression body against this shell's
    /// environment, returning the numeric result.
    ///
    /// Unset variables evaluate as 0. Assignments inside the expression
    /// are written back to `environment.variables` as decimal strings.
    func evaluateArithmetic(_ expression: String) throws -> Int64 {
        try Arithmetic.evaluate(
            expression,
            get: { [environment] name in environment.variables[name] },
            set: { [weak self] name, value in
                self?.environment.variables[name] = String(value)
            }
        )
    }

    /// Run a standalone `((expression))` command. Exit status follows
    /// bash's inverted convention: non-zero result → `.success`,
    /// zero result → `.failure`.
    func runArithmeticCommand(_ expression: String) throws -> ExitStatus {
        let value = try evaluateArithmetic(expression)
        return value != 0 ? .success : .failure
    }
}
