import ArgumentParser
import BashInterpreter
import Foundation

/// `pkill PATTERN` — cancel virtual background jobs whose command
/// label matches `PATTERN` (regex). Operates on
/// ``Shell/processTable``; never touches the host process table.
public struct PkillCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pkill",
        abstract: "Cancel virtual background jobs by name."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then PATTERN")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var sig: Int32 = SIGTERM
        var pattern: String? = nil
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-f" { i += 1; continue }    // -f is a no-op here
            if a == "-s" {
                guard i + 1 < rawArgv.count, let s = parseSignal(rawArgv[i + 1]) else {
                    Shell.bashCurrent.stderr("pkill: invalid signal\n"); return ExitStatus(2)
                }
                sig = s; i += 2; continue
            }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                let body = String(a.dropFirst())
                if body == "f" { i += 1; continue }
                if let s = parseSignal(body) { sig = s; i += 1; continue }
                Shell.bashCurrent.stderr("pkill: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            pattern = a; i += 1
        }
        guard let pat = pattern else {
            Shell.bashCurrent.stderr("pkill: missing pattern\n")
            return ExitStatus(2)
        }
        guard let regex = try? NSRegularExpression(pattern: pat) else {
            Shell.bashCurrent.stderr("pkill: invalid pattern\n")
            return ExitStatus(2)
        }
        let table = Shell.bashCurrent.processTable
        let entries = await table.list()
        let matches = entries.filter { e in
            let ns = e.command as NSString
            return regex.firstMatch(in: e.command,
                                    range: NSRange(location: 0, length: ns.length)) != nil
        }
        for e in matches {
            _ = await table.signal(pid: e.pid, signo: sig)
        }
        return matches.isEmpty ? ExitStatus(1) : .success
    }
}
