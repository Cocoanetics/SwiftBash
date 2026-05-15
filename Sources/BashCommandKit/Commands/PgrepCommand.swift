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

    // swiftlint:disable:next cyclomatic_complexity
    public mutating func execute() async throws -> ExitStatus {
        var listLong = false
        var pattern: String?
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "-l" { listLong = true; index += 1; continue }
            if arg == "-f" {
                // -f matches the full command — that's already what
                // we store in the entry, so this is a no-op for us.
                index += 1; continue
            }
            if arg.hasPrefix("-") && arg.count > 1 && arg != "-" {
                for char in arg.dropFirst() {
                    switch char {
                    case "l": listLong = true
                    case "f": break
                    default:
                        Shell.bashCurrent.stderr("pgrep: unknown option: -\(char)\n")
                        return ExitStatus(2)
                    }
                }
                index += 1; continue
            }
            pattern = arg; index += 1
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
        let matches = entries.filter { entry in
            let nsString = entry.command as NSString
            return regex.firstMatch(in: entry.command,
                                    range: NSRange(location: 0, length: nsString.length)) != nil
        }
        for entry in matches {
            if listLong {
                Shell.bashCurrent.stdout("\(entry.pid) \(entry.command)\n")
            } else {
                Shell.bashCurrent.stdout("\(entry.pid)\n")
            }
        }
        return matches.isEmpty ? ExitStatus(1) : .success
    }
}
