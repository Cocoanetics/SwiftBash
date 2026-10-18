import Foundation

/// `break [N]` — exit from an enclosing `for`, `while`, or `until` loop.
///
/// With `N`, break out of N levels of loops. N must be ≥ 1. When the
/// value exceeds the number of enclosing loops, all of them are exited
/// (matching bash).
///
/// Implementation note: the built-in throws a ``LoopControlSignal``
/// that the nearest loop handler catches, through `eval` and `source`.
/// Outside any loop — ``Shell/loopDepth`` is 0, as it is in a function
/// body — it prints bash's warning instead and returns 0.
public struct BreakCommand: Command {
    public let name = "break"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let levels = try parseLevels(argv, builtin: name)
        let signal = LoopControlSignal(kind: .breakLoop, remainingLevels: levels)
        // Outside any loop (a function body doesn't see its caller's
        // loops), bash warns and carries on with status 0.
        guard Shell.bashCurrent.loopDepth > 0 else {
            Shell.bashCurrent.warnStrayLoopControl(signal)
            return .success
        }
        throw signal
    }
}

/// Parse the optional `N` argument for break/continue.
func parseLevels(_ argv: [String], builtin: String) throws -> Int {
    guard let raw = argv.dropFirst().first else { return 1 }
    guard let count = Int(raw), count >= 1 else {
        throw BashInterpreterError.invalidArguments(
            builtin: builtin,
            message: "loop count out of range: \(raw)")
    }
    return count
}
