import Foundation

/// `let EXPR…` — evaluate each ARG as a bash arithmetic expression in
/// the current shell. Assignments inside the expression (`x=5`,
/// `((x++))`-style) take effect on shell variables.
///
/// Exit status: 0 if the *last* expression evaluated to non-zero, 1 if
/// it evaluated to zero (matching bash's "true == non-zero" arithmetic
/// truthiness so `let x=0 || …` behaves correctly).
public struct LetCommand: Command {
    public let name = "let"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let exprs = argv.dropFirst()
        if exprs.isEmpty {
            Shell.current.stderr("let: expression expected\n")
            return ExitStatus(2)
        }
        var lastValue: Int64 = 0
        for expr in exprs {
            lastValue = try await Shell.current.evaluateArithmetic(expr)
        }
        return lastValue != 0 ? .success : .failure
    }
}
