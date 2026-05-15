import Foundation

/// `break [N]` — exit from an enclosing `for`, `while`, or `until` loop.
///
/// With `N`, break out of N levels of loops. N must be ≥ 1. When the
/// value exceeds the number of enclosing loops, all of them are exited
/// (matching bash).
///
/// Implementation note: the built-in itself doesn't know how many loops
/// are currently running — it throws a ``LoopControlSignal`` that the
/// nearest loop handler catches. Outside any loop, the top-level
/// ``Shell/run(_:)`` catches it and prints a bash-style warning.
public struct BreakCommand: Command {
    public let name = "break"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let levels = try parseLevels(argv, builtin: name)
        throw LoopControlSignal(kind: .breakLoop, remainingLevels: levels)
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
