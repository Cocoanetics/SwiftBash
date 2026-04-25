import Foundation

/// `return [N]` — return from the enclosing function with status `N`
/// (default: the current `$?`). Outside a function (or sourced
/// script) this is an error in bash; we warn on stderr.
public struct ReturnCommand: Command {
    public let name = "return"
    public init() {}

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        if shell.functionCallDepth == 0 {
            shell.stderr("return: can only `return' from a function or sourced script\n")
            return .failure
        }
        let status: ExitStatus
        if let raw = argv.dropFirst().first {
            guard let n = Int32(raw) else {
                shell.stderr("return: \(raw): numeric argument required\n")
                return ExitStatus(2)
            }
            status = ExitStatus(n)
        } else {
            status = shell.lastExitStatus
        }
        throw ReturnSignal(status: status)
    }
}
