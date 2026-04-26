import ArgumentParser
import BashInterpreter
import Foundation

/// `kill [-SIG] PID...` — send a signal (default TERM) to one or more
/// processes.
public struct KillCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Send a signal to a process."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then PID...")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var signal: Int32 = SIGTERM
        var pids: [Int32] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-l" || a == "--list" {
                listSignals()
                return .success
            }
            if a == "-s" {
                guard i + 1 < rawArgv.count, let sig = parseSignal(rawArgv[i + 1]) else {
                    Shell.current.stderr("kill: invalid signal\n"); return ExitStatus(2)
                }
                signal = sig; i += 2; continue
            }
            if a.hasPrefix("-") && a != "--" && a.count > 1 {
                let sigPart = String(a.dropFirst())
                if let sig = parseSignal(sigPart) {
                    signal = sig
                } else {
                    Shell.current.stderr("kill: invalid signal: \(a)\n")
                    return ExitStatus(2)
                }
                i += 1; continue
            }
            if let pid = Int32(a) {
                pids.append(pid)
            } else {
                Shell.current.stderr("kill: invalid PID: \(a)\n")
                return ExitStatus(2)
            }
            i += 1
        }
        guard !pids.isEmpty else {
            Shell.current.stderr("kill: usage: kill [-SIG] PID...\n")
            return ExitStatus(2)
        }
        var hadError = false
        for pid in pids {
            if Foundation.kill(pid, signal) != 0 {
                let msg = String(cString: strerror(errno))
                Shell.current.stderr("kill: \(pid): \(msg)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func listSignals() {
        let signals: [(String, Int32)] = [
            ("HUP", SIGHUP), ("INT", SIGINT), ("QUIT", SIGQUIT),
            ("ILL", SIGILL), ("TRAP", SIGTRAP), ("ABRT", SIGABRT),
            ("FPE", SIGFPE), ("KILL", SIGKILL), ("BUS", SIGBUS),
            ("SEGV", SIGSEGV), ("SYS", SIGSYS), ("PIPE", SIGPIPE),
            ("ALRM", SIGALRM), ("TERM", SIGTERM), ("URG", SIGURG),
            ("STOP", SIGSTOP), ("TSTP", SIGTSTP), ("CONT", SIGCONT),
            ("CHLD", SIGCHLD), ("TTIN", SIGTTIN), ("TTOU", SIGTTOU),
            ("USR1", SIGUSR1), ("USR2", SIGUSR2),
        ]
        Shell.current.stdout(signals.map { "\($0.1)) \($0.0)" }.joined(separator: " ") + "\n")
    }
}
