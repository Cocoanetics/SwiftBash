import ArgumentParser
import BashInterpreter
import Foundation

/// `nohup COMMAND [ARG...]` — run a command immune to hangups.
///
/// In our shell there are no real signals to ignore, so this is a
/// thin wrapper that runs the command and emits the standard
/// "appending output to nohup.out" notice on stderr (only when the
/// destination differs from stdin's fd, which is always the case
/// here since stdin is treated as a tty stand-in).
public struct NohupCommand: Command {
    public let name = "nohup"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())
        guard !args.isEmpty else {
            Shell.current.stderr("nohup: usage: nohup COMMAND [ARG...]\n")
            return ExitStatus(127)
        }
        let line = args.map(shellQuote).joined(separator: " ")
        Shell.current.stderr("nohup: ignoring input and appending output to 'nohup.out'\n")
        return try await Shell.current.run(line)
    }

    private func shellQuote(_ s: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !s.isEmpty && s.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
