import Foundation

/// `continue [N]` — resume the next iteration of an enclosing
/// `for`, `while`, or `until` loop.
///
/// With `N`, unwind `N-1` enclosing loops, then continue at the N-th.
public struct ContinueBuiltin: Builtin {
    public let name = "continue"
    public init() {}

    public func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
        let levels = try parseLevels(argv, builtin: name)
        throw LoopControlSignal(kind: .continueLoop, remainingLevels: levels)
    }
}
