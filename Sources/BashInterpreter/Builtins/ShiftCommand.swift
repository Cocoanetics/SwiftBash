import Foundation

/// `shift [N]` — drop the first N positional parameters. Default N is 1.
/// Returns failure if `N` exceeds the available count, matching bash.
public struct ShiftCommand: Command {
    public let name = "shift"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())
        let n: Int
        if let raw = args.first {
            guard let parsed = Int(raw), parsed >= 0 else {
                Shell.bashCurrent.stderr("shift: \(raw): numeric argument required\n")
                return .failure
            }
            n = parsed
        } else {
            n = 1
        }
        if n > Shell.bashCurrent.positionalParameters.count {
            return .failure
        }
        Shell.bashCurrent.positionalParameters.removeFirst(n)
        return .success
    }
}
