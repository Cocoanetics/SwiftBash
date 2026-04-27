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

    public mutating func execute() async throws -> ExitStatus {
        var pidFilter: Set<Int32>? = nil
        var columns: [String] = ["pid", "state", "command"]
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-p" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("ps: -p requires PIDs\n"); return ExitStatus(2)
                }
                pidFilter = Set(rawArgv[i + 1].split(separator: ",")
                    .compactMap { Int32($0) })
                i += 2; continue
            }
            if a == "-o" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("ps: -o requires COL list\n"); return ExitStatus(2)
                }
                columns = rawArgv[i + 1]
                    .split(whereSeparator: { $0 == "," || $0 == " " })
                    .map { String($0).lowercased() }
                i += 2; continue
            }
            if a == "-A" || a == "-e" || a == "-a" || a == "-x" { i += 1; continue }
            if a.hasPrefix("-") && a != "-" {
                for c in a.dropFirst() {
                    switch c {
                    case "A", "e", "a", "x": break
                    default:
                        Shell.current.stderr("ps: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            i += 1
        }

        let entries = await Shell.current.processTable.list()
            .filter { pidFilter?.contains($0.pid) ?? true }

        Shell.current.stdout(
            columns.map(columnHeader).joined(separator: "  ") + "\n")
        for e in entries {
            Shell.current.stdout(
                columns.map { columnValue($0, of: e) }
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
                             of e: ProcessTable.Entry) -> String
    {
        switch name {
        case "pid":  return String(format: "%5d", e.pid)
        case "ppid": return String(format: "%5d", Shell.current.virtualPID)
        case "state":
            switch e.state {
            case .running:   return "R   "
            case .exited:    return "Z   "
            case .failed:    return "X   "
            case .cancelled: return "T   "
            }
        case "time":
            let elapsed = Date().timeIntervalSince(e.startedAt)
            return String(format: "%9.2fs", elapsed)
        case "command", "cmd", "comm":
            return e.command
        default: return ""
        }
    }
}
