import ArgumentParser
import BashInterpreter
import Foundation

/// `pgrep PATTERN` — print PIDs of virtual background jobs whose
/// command label matches `PATTERN` (regex). Operates exclusively on
/// the shell's ``Shell/processTable`` — never the host process table.
public struct PgrepCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pgrep",
        abstract: "Look up virtual background jobs by name."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then PATTERN")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var listLong = false
        var pattern: String? = nil
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-l" { listLong = true; i += 1; continue }
            if a == "-f" {
                // -f matches the full command — that's already what
                // we store in the entry, so this is a no-op for us.
                i += 1; continue
            }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                for c in a.dropFirst() {
                    switch c {
                    case "l": listLong = true
                    case "f": break
                    default:
                        Shell.bashCurrent.stderr("pgrep: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            pattern = a; i += 1
        }
        guard let pat = pattern else {
            Shell.bashCurrent.stderr("pgrep: missing pattern\n")
            return ExitStatus(2)
        }
        guard let regex = try? NSRegularExpression(pattern: pat) else {
            Shell.bashCurrent.stderr("pgrep: invalid pattern\n")
            return ExitStatus(2)
        }
        let entries = await Shell.bashCurrent.processTable.list()
        let matches = entries.filter { e in
            let ns = e.command as NSString
            return regex.firstMatch(in: e.command,
                                    range: NSRange(location: 0, length: ns.length)) != nil
        }
        for e in matches {
            if listLong {
                Shell.bashCurrent.stdout("\(e.pid) \(e.command)\n")
            } else {
                Shell.bashCurrent.stdout("\(e.pid)\n")
            }
        }
        return matches.isEmpty ? ExitStatus(1) : .success
    }
}
