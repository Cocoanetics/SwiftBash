import Foundation

/// `return [N]` — return from the enclosing function with status `N`
/// (default: the current `$?`). Outside a function (or sourced
/// script) this is an error in bash; we warn on stderr.
public struct ReturnCommand: Command {
    public let name = "return"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        if Shell.bashCurrent.functionCallDepth == 0 {
            Shell.bashCurrent.stderr("return: can only `return' from a function or sourced script\n")
            return .failure
        }
        let status: ExitStatus
        if let raw = argv.dropFirst().first {
            guard let num = Int32(raw) else {
                Shell.bashCurrent.stderr("return: \(raw): numeric argument required\n")
                return ExitStatus(2)
            }
            status = ExitStatus(num)
        } else {
            status = Shell.bashCurrent.lastExitStatus
        }
        throw ReturnSignal(status: status)
    }
}
