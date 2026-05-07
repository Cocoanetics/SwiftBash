import Foundation

/// `wait [PID…]` — block until the given background jobs finish.
///
/// Forms:
/// - `wait`       — wait for every still-running background job; exit
///                  status is the last awaited status (0 if there were
///                  no jobs).
/// - `wait PID…`  — wait for each PID in turn; exit status is the
///                  last one's status. Unknown PID returns 127.
/// - `wait $!`    — common idiom: wait for the most recently spawned
///                  background job. Resolved by parameter expansion
///                  before this command sees it.
///
/// Job-spec forms (`%N`, `%+`, `%-`) are not yet supported — bash
/// tools that use them are rare in non-interactive scripts.
public struct WaitCommand: Command {
    public let name = "wait"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let table = Shell.bashCurrent.processTable
        let pidArgs = argv.dropFirst()

        if pidArgs.isEmpty {
            return await table.waitAll()
        }

        var last: ExitStatus = .success
        for arg in pidArgs {
            guard let pid = Int32(arg) else {
                Shell.bashCurrent.stderr(
                    "wait: \(arg): not a valid pid or job spec\n")
                return ExitStatus(127)
            }
            if let status = await table.wait(pid: pid) {
                last = status
            } else {
                // bash returns 127 for "no such process is a child"
                Shell.bashCurrent.stderr(
                    "wait: pid \(pid) is not a child of this shell\n")
                last = ExitStatus(127)
            }
        }
        return last
    }
}
