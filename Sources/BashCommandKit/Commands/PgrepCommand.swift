import ArgumentParser
import BashInterpreter
import Foundation

/// `pgrep PATTERN` — print PIDs of processes whose name matches.
/// `pkill PATTERN` — same lookup, but signal each match.
public struct PgrepCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pgrep",
        abstract: "Look up processes by name."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then PATTERN")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var listLong = false
        var fullCommand = false
        var pattern: String? = nil
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-l" { listLong = true; i += 1; continue }
            if a == "-f" { fullCommand = true; i += 1; continue }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                for c in a.dropFirst() {
                    switch c {
                    case "l": listLong = true
                    case "f": fullCommand = true
                    default:
                        Shell.current.stderr("pgrep: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            pattern = a; i += 1
        }
        guard let pat = pattern else {
            Shell.current.stderr("pgrep: missing pattern\n")
            return ExitStatus(2)
        }
        guard let regex = try? NSRegularExpression(pattern: pat) else {
            Shell.current.stderr("pgrep: invalid pattern\n")
            return ExitStatus(2)
        }
        let matches = ProcessList.allProcesses().filter { p in
            let target = fullCommand ? p.command : p.comm
            let ns = target as NSString
            return regex.firstMatch(in: target,
                                    range: NSRange(location: 0, length: ns.length)) != nil
        }
        for p in matches {
            if listLong {
                Shell.current.stdout("\(p.pid) \(p.comm)\n")
            } else {
                Shell.current.stdout("\(p.pid)\n")
            }
        }
        return matches.isEmpty ? ExitStatus(1) : .success
    }
}
