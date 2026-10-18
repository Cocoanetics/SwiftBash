import Foundation

/// `continue [N]` — resume the next iteration of an enclosing
/// `for`, `while`, or `until` loop.
///
/// With `N`, unwind `N-1` enclosing loops, then continue at the N-th.
public struct ContinueCommand: Command {
    public let name = "continue"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let levels = try parseLevels(argv, builtin: name)
        let signal = LoopControlSignal(kind: .continueLoop, remainingLevels: levels)
        // Outside any loop (a function body doesn't see its caller's
        // loops), bash warns and carries on with status 0.
        guard Shell.bashCurrent.loopDepth > 0 else {
            Shell.bashCurrent.warnStrayLoopControl(signal)
            return .success
        }
        throw signal
    }
}
