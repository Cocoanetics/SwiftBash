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
        var signalNum: Int32 = SIGTERM
        var pattern: String?
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "-f" { index += 1; continue }    // -f is a no-op here
            if arg == "-s" {
                guard index + 1 < rawArgv.count,
                      let parsed = parseSignal(rawArgv[index + 1]) else {
                    Shell.bashCurrent.stderr("pkill: invalid signal\n")
                    return ExitStatus(2)
                }
                signalNum = parsed; index += 2; continue
            }
            if arg.hasPrefix("-") && arg.count > 1 && arg != "-" {
                let body = String(arg.dropFirst())
                if body == "f" { index += 1; continue }
                if let parsed = parseSignal(body) {
                    signalNum = parsed; index += 1; continue
                }
                Shell.bashCurrent.stderr("pkill: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            pattern = arg; index += 1
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
        let matches = entries.filter { entry in
            let nsCmd = entry.command as NSString
            return regex.firstMatch(in: entry.command,
                                    range: NSRange(location: 0, length: nsCmd.length)) != nil
        }
        for entry in matches {
            _ = await table.signal(pid: entry.pid, signo: signalNum)
        }
        return matches.isEmpty ? ExitStatus(1) : .success
    }
}
