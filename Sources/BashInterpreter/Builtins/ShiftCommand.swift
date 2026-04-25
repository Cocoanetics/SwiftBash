import Foundation

/// `shift [N]` — drop the first N positional parameters. Default N is 1.
/// Returns failure if `N` exceeds the available count, matching bash.
public struct ShiftCommand: Command {
    public let name = "shift"
    public init() {}

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())
        let n: Int
        if let raw = args.first {
            guard let parsed = Int(raw), parsed >= 0 else {
                shell.stderr("shift: \(raw): numeric argument required\n")
                return .failure
            }
            n = parsed
        } else {
            n = 1
        }
        if n > shell.positionalParameters.count {
            return .failure
        }
        shell.positionalParameters.removeFirst(n)
        return .success
    }
}
