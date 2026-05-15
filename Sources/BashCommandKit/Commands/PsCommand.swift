import ArgumentParser
import BashInterpreter
import Foundation

/// `ps [OPTIONS]` — list this shell's virtual process table.
///
/// **Virtual only.** Lists background jobs spawned with `&` and any
/// other entries the shell registered in ``Shell/processTable``. The
/// real host process table is never consulted — a script under
/// SwiftBash cannot enumerate processes outside its own shell tree.
///
/// Supported flags (most BSD options accepted as no-ops since there's
/// no UID/TTY/etc. to filter on):
/// - `-A` / `-e` — list all entries (the default)
/// - `-x` / `-a` — accepted, no-op
/// - `-p PID,...` — restrict to specific PIDs
/// - `-o COL,...` — pick output columns: `pid`, `ppid`, `command`,
///   `comm`, `state`, `time`
public struct PsCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "Display this shell's virtual background jobs."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS")
    public var rawArgv: [String] = []

    public init() {}

    // swiftlint:disable:next cyclomatic_complexity
    public mutating func execute() async throws -> ExitStatus {
        var pidFilter: Set<Int32>?
        var columns: [String] = ["pid", "state", "command"]
        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "-p" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("ps: -p requires PIDs\n"); return ExitStatus(2)
                }
                pidFilter = Set(rawArgv[idx + 1].split(separator: ",")
                    .compactMap { Int32($0) })
                idx += 2; continue
            }
            if arg == "-o" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("ps: -o requires COL list\n"); return ExitStatus(2)
                }
                columns = rawArgv[idx + 1]
                    .split(whereSeparator: { $0 == "," || $0 == " " })
                    .map { String($0).lowercased() }
                idx += 2; continue
            }
            if arg == "-A" || arg == "-e" || arg == "-a" || arg == "-x" { idx += 1; continue }
            if arg.hasPrefix("-") && arg != "-" {
                for char in arg.dropFirst() {
                    switch char {
                    case "A", "e", "a", "x": break
                    default:
                        Shell.bashCurrent.stderr("ps: unknown option: -\(char)\n")
                        return ExitStatus(2)
                    }
                }
                idx += 1; continue
            }
            idx += 1
        }

        let entries = await Shell.bashCurrent.processTable.list()
            .filter { pidFilter?.contains($0.pid) ?? true }

        Shell.bashCurrent.stdout(
            columns.map(columnHeader).joined(separator: "  ") + "\n")
        for entry in entries {
            Shell.bashCurrent.stdout(
                columns.map { columnValue($0, of: entry) }
                    .joined(separator: "  ") + "\n")
        }
        return .success
    }

    private func columnHeader(_ name: String) -> String {
        switch name {
        case "pid":            return "  PID"
        case "ppid":           return " PPID"
        case "state":          return "STAT"
        case "time":           return "TIME      "
        case "command", "comm", "cmd": return "COMMAND"
        default: return name.uppercased()
        }
    }

    private func columnValue(_ name: String,
                             of entry: ProcessTable.Entry) -> String {
        switch name {
        case "pid":  return String(format: "%5d", entry.pid)
        case "ppid": return String(format: "%5d", Shell.bashCurrent.virtualPID)
        case "state":
            switch entry.state {
            case .running:   return "R   "
            case .exited:    return "Z   "
            case .failed:    return "X   "
            case .cancelled: return "T   "
            }
        case "time":
            let elapsed = Date().timeIntervalSince(entry.startedAt)
            return String(format: "%9.2fs", elapsed)
        case "command", "cmd", "comm":
            return entry.command
        default: return ""
        }
    }
}
