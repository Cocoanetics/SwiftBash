import ArgumentParser
import BashInterpreter
import Foundation

/// `ps [OPTIONS]` — list host processes via `sysctl(KERN_PROC_ALL)`.
///
/// Supported flags (BSD-style, since this targets macOS):
/// - `-A` / `-e` — all processes (default; ours always lists all)
/// - `-x` — include processes without a controlling terminal (no-op)
/// - `-a` — others' processes too (no-op)
/// - `-p PID,...` — restrict to specific PIDs (comma-separated)
/// - `-o COL,COL,...` — output columns (subset: pid, ppid, command, comm)
public struct PsCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "Display running processes."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var pidFilter: Set<Int32>? = nil
        var columns: [String] = ["pid", "command"]
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-p" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("ps: -p requires PIDs\n"); return ExitStatus(2)
                }
                pidFilter = Set(rawArgv[i + 1].split(separator: ",").compactMap { Int32($0) })
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
                // Bundled forms like -ax, -ef
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
        let procs = ProcessList.allProcesses()
            .filter { pidFilter?.contains($0.pid) ?? true }
        emit(procs, columns: columns)
        return .success
    }

    private func emit(_ procs: [ProcessInfo_], columns: [String]) {
        // Header.
        Shell.current.stdout(columns.map { columnHeader($0) }.joined(separator: " ") + "\n")
        for p in procs {
            Shell.current.stdout(columns.map { columnValue($0, of: p) }.joined(separator: " ") + "\n")
        }
    }

    private func columnHeader(_ name: String) -> String {
        switch name {
        case "pid": return "  PID"
        case "ppid": return " PPID"
        case "command", "comm", "cmd": return "COMMAND"
        default: return name.uppercased()
        }
    }

    private func columnValue(_ name: String, of p: ProcessInfo_) -> String {
        switch name {
        case "pid":  return String(format: "%5d", p.pid)
        case "ppid": return String(format: "%5d", p.ppid)
        case "command", "cmd": return p.command
        case "comm": return p.comm
        default: return ""
        }
    }
}
