import Foundation

/// `exit [N]` — terminate shell execution with status `N`
/// (or the last command's exit status if `N` is omitted).
///
/// Internally this throws ``ShellExit`` to unwind the interpreter; the
/// top-level `Shell.run` catches it and returns the carried status.
public struct ExitCommand: Command {
    public let name = "exit"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let status: ExitStatus
        if let raw = argv.dropFirst().first {
            guard let n = Int32(raw) else {
                throw BashInterpreterError.invalidArguments(
                    builtin: "exit",
                    message: "numeric argument required: \(raw)")
            }
            status = ExitStatus(n)
        } else {
            status = Shell.current.lastExitStatus
        }
        throw ShellExit(status: status)
    }
}

/// Internal sentinel thrown by `exit` to unwind execution.
struct ShellExit: Error {
    let status: ExitStatus
}
