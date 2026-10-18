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
            guard let code = Int32(raw) else {
                throw BashInterpreterError.invalidArguments(
                    builtin: "exit",
                    message: "numeric argument required: \(raw)")
            }
            status = ExitStatus(code)
        } else {
            status = Shell.bashCurrent.lastExitStatus
        }
        throw ShellExit(status: status)
    }
}

/// Internal sentinel thrown by `exit` to unwind execution.
struct ShellExit: Error {
    let status: ExitStatus
}

/// Bash's "discard": an assignment error such as `UID=5` abandons the
/// rest of the top-level command — the rest of the line, an enclosing
/// group, loop or function call — and the shell goes on with the next
/// one, `$?` being 1. Each run (a script, `source`, `eval`, a trap)
/// catches it per command; a subshell that sees it ends with `status`.
struct DiscardCommand: Error {
    /// `$?` afterwards: 1, or 2 for an expansion such as `${UID[1]:=5}`.
    var status: ExitStatus = .failure
}
