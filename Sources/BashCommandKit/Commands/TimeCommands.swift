import ArgumentParser
import BashInterpreter
import Foundation

/// `time COMMAND [ARG...]` — run a command and report how long it
/// took. Output is written to stderr in the standard `real / user /
/// sys` shape (we don't have CPU-time accounting, so user/sys are
/// reported as `0m0.000s`).
public struct TimeCommand: Command {
    public let name = "time"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())
        if args.contains("--version") {
            Shell.bashCurrent.stdout("time (SwiftBash) \(SwiftBashVersion.packageVersion)\n")
            return .success
        }
        guard !args.isEmpty else {
            Shell.bashCurrent.stderr("time: usage: time COMMAND [ARG...]\n")
            return ExitStatus(2)
        }
        let start = Date()
        let line = args.map(shellQuote).joined(separator: " ")
        let status: ExitStatus
        do {
            status = try await Shell.bashCurrent.run(line)
        } catch {
            Shell.bashCurrent.stderr("time: \(error)\n")
            return ExitStatus(126)
        }
        let elapsed = Date().timeIntervalSince(start)
        let realStr = formatDuration(elapsed)
        Shell.bashCurrent.stderr("\nreal\t\(realStr)\nuser\t0m0.000s\nsys\t0m0.000s\n")
        return status
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        let secs = seconds - Double(mins) * 60
        return String(format: "%dm%.3fs", mins, secs)
    }

    private func shellQuote(_ source: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !source.isEmpty && source.allSatisfy({ safe.contains($0) }) { return source }
        return "'" + source.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// `timeout DURATION COMMAND [ARG...]` — run a command, killing it
/// after DURATION (a number with optional `s`/`m`/`h`/`d` suffix).
///
/// Returns 124 if the command is killed by the deadline; otherwise
/// the command's own exit status.
public struct TimeoutCommand: Command {
    public let name = "timeout"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var args = Array(argv.dropFirst())
        if args.contains("--version") {
            Shell.bashCurrent.stdout("timeout (SwiftBash) \(SwiftBashVersion.packageVersion)\n")
            return .success
        }
        // Skip the GNU --foreground / --preserve-status / -k flags
        // we don't honour.
        while let first = args.first {
            if first == "--foreground" || first == "--preserve-status" {
                args.removeFirst(); continue
            }
            if first == "-k" || first == "--kill-after" {
                args.removeFirst()
                if !args.isEmpty { args.removeFirst() }
                continue
            }
            if first.hasPrefix("-k=") || first.hasPrefix("--kill-after=") {
                args.removeFirst(); continue
            }
            break
        }
        guard args.count >= 2 else {
            Shell.bashCurrent.stderr("timeout: usage: timeout DURATION COMMAND [ARG...]\n")
            return ExitStatus(2)
        }
        guard let seconds = parseDuration(args[0]) else {
            Shell.bashCurrent.stderr("timeout: invalid duration: \(args[0])\n")
            return ExitStatus(2)
        }
        let cmd = Array(args.dropFirst())
        let line = cmd.map(shellQuote).joined(separator: " ")

        // Race the command against a sleep. The interpreter doesn't
        // give us a way to actually kill an in-flight `Shell.bashCurrent.run`, so
        // when the timer fires we surface 124 to the caller; the
        // command task is left to complete in the background. Good
        // enough for orchestration and tests, though not as tight as
        // GNU timeout's signal delivery.
        return try await withThrowingTaskGroup(of: TimeoutResult.self) { group in
            group.addTask {
                let status = try await Shell.bashCurrent.run(line)
                return .completed(status)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timedOut
            }
            for try await result in group {
                group.cancelAll()
                switch result {
                case .completed(let status): return status
                case .timedOut:
                    Shell.bashCurrent.stderr("timeout: command timed out\n")
                    return ExitStatus(124)
                }
            }
            return ExitStatus(0)
        }
    }

    private enum TimeoutResult { case completed(ExitStatus), timedOut }

    private func parseDuration(_ source: String) -> Double? {
        var rest = source
        var mult = 1.0
        if let last = rest.last {
            switch last {
            case "s": mult = 1; rest.removeLast()
            case "m": mult = 60; rest.removeLast()
            case "h": mult = 3600; rest.removeLast()
            case "d": mult = 86400; rest.removeLast()
            default: break
            }
        }
        guard let value = Double(rest), value >= 0 else { return nil }
        return value * mult
    }

    private func shellQuote(_ source: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !source.isEmpty && source.allSatisfy({ safe.contains($0) }) { return source }
        return "'" + source.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
