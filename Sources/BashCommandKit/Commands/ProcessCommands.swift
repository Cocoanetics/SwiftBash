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

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var pidFilter: Set<Int32>? = nil
        var columns: [String] = ["pid", "command"]
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-p" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("ps: -p requires PIDs\n"); return ExitStatus(2)
                }
                pidFilter = Set(rawArgv[i + 1].split(separator: ",").compactMap { Int32($0) })
                i += 2; continue
            }
            if a == "-o" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("ps: -o requires COL list\n"); return ExitStatus(2)
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
                        shell.stderr("ps: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            i += 1
        }
        let procs = ProcessList.allProcesses()
            .filter { pidFilter?.contains($0.pid) ?? true }
        emit(procs, columns: columns, shell: shell)
        return .success
    }

    private func emit(_ procs: [ProcessInfo_], columns: [String], shell: Shell) {
        // Header.
        shell.stdout(columns.map { columnHeader($0) }.joined(separator: " ") + "\n")
        for p in procs {
            shell.stdout(columns.map { columnValue($0, of: p) }.joined(separator: " ") + "\n")
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

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var signal: Int32 = SIGTERM
        var pids: [Int32] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-l" || a == "--list" {
                listSignals(shell: shell)
                return .success
            }
            if a == "-s" {
                guard i + 1 < rawArgv.count, let sig = parseSignal(rawArgv[i + 1]) else {
                    shell.stderr("kill: invalid signal\n"); return ExitStatus(2)
                }
                signal = sig; i += 2; continue
            }
            if a.hasPrefix("-") && a != "--" && a.count > 1 {
                let sigPart = String(a.dropFirst())
                if let sig = parseSignal(sigPart) {
                    signal = sig
                } else {
                    shell.stderr("kill: invalid signal: \(a)\n")
                    return ExitStatus(2)
                }
                i += 1; continue
            }
            if let pid = Int32(a) {
                pids.append(pid)
            } else {
                shell.stderr("kill: invalid PID: \(a)\n")
                return ExitStatus(2)
            }
            i += 1
        }
        guard !pids.isEmpty else {
            shell.stderr("kill: usage: kill [-SIG] PID...\n")
            return ExitStatus(2)
        }
        var hadError = false
        for pid in pids {
            if Foundation.kill(pid, signal) != 0 {
                let msg = String(cString: strerror(errno))
                shell.stderr("kill: \(pid): \(msg)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func listSignals(shell: Shell) {
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
        shell.stdout(signals.map { "\($0.1)) \($0.0)" }.joined(separator: " ") + "\n")
    }
}

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

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
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
                        shell.stderr("pgrep: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            pattern = a; i += 1
        }
        guard let pat = pattern else {
            shell.stderr("pgrep: missing pattern\n")
            return ExitStatus(2)
        }
        guard let regex = try? NSRegularExpression(pattern: pat) else {
            shell.stderr("pgrep: invalid pattern\n")
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
                shell.stdout("\(p.pid) \(p.comm)\n")
            } else {
                shell.stdout("\(p.pid)\n")
            }
        }
        return matches.isEmpty ? ExitStatus(1) : .success
    }
}

public struct PkillCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pkill",
        abstract: "Signal processes by name."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then PATTERN")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var sig: Int32 = SIGTERM
        var fullCommand = false
        var pattern: String? = nil
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-f" { fullCommand = true; i += 1; continue }
            if a == "-s" {
                guard i + 1 < rawArgv.count, let s = parseSignal(rawArgv[i + 1]) else {
                    shell.stderr("pkill: invalid signal\n"); return ExitStatus(2)
                }
                sig = s; i += 2; continue
            }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                let body = String(a.dropFirst())
                if body == "f" { fullCommand = true; i += 1; continue }
                if let s = parseSignal(body) { sig = s; i += 1; continue }
                shell.stderr("pkill: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            pattern = a; i += 1
        }
        guard let pat = pattern else {
            shell.stderr("pkill: missing pattern\n")
            return ExitStatus(2)
        }
        guard let regex = try? NSRegularExpression(pattern: pat) else {
            shell.stderr("pkill: invalid pattern\n")
            return ExitStatus(2)
        }
        let matches = ProcessList.allProcesses().filter { p in
            let target = fullCommand ? p.command : p.comm
            let ns = target as NSString
            return regex.firstMatch(in: target,
                                    range: NSRange(location: 0, length: ns.length)) != nil
        }
        var hadError = false
        for p in matches {
            if Foundation.kill(p.pid, sig) != 0 {
                shell.stderr("pkill: \(p.pid): \(String(cString: strerror(errno)))\n")
                hadError = true
            }
        }
        return matches.isEmpty ? ExitStatus(1) : (hadError ? .failure : .success)
    }
}

// MARK: - Shared signal parsing & process listing

/// Parse `9` / `KILL` / `SIGKILL` into the numeric value.
fileprivate func parseSignal(_ s: String) -> Int32? {
    if let n = Int32(s) { return n }
    var name = s.uppercased()
    if name.hasPrefix("SIG") { name.removeFirst(3) }
    let map: [String: Int32] = [
        "HUP": SIGHUP, "INT": SIGINT, "QUIT": SIGQUIT,
        "ILL": SIGILL, "TRAP": SIGTRAP, "ABRT": SIGABRT,
        "FPE": SIGFPE, "KILL": SIGKILL, "BUS": SIGBUS,
        "SEGV": SIGSEGV, "SYS": SIGSYS, "PIPE": SIGPIPE,
        "ALRM": SIGALRM, "TERM": SIGTERM, "URG": SIGURG,
        "STOP": SIGSTOP, "TSTP": SIGTSTP, "CONT": SIGCONT,
        "CHLD": SIGCHLD, "TTIN": SIGTTIN, "TTOU": SIGTTOU,
        "USR1": SIGUSR1, "USR2": SIGUSR2,
    ]
    return map[name]
}

/// Per-process snapshot used by `ps` / `pgrep` / `pkill`.
struct ProcessInfo_ {
    let pid: Int32
    let ppid: Int32
    let comm: String     // short name
    let command: String  // full path or argv[0]
}

/// Wraps `sysctl(KERN_PROC_ALL)` to enumerate processes on Darwin.
enum ProcessList {

    static func allProcesses() -> [ProcessInfo_] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: size_t = 0
        // First call to size the buffer.
        if sysctl(&name, 4, nil, &size, nil, 0) != 0 { return [] }
        let count = size / MemoryLayout<kinfo_proc>.size
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.size
        if sysctl(&name, 4, &buf, &size, nil, 0) != 0 { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.size

        var procs: [ProcessInfo_] = []
        procs.reserveCapacity(actual)
        for i in 0..<actual {
            var entry = buf[i]
            let pid = entry.kp_proc.p_pid
            let ppid = entry.kp_eproc.e_ppid
            // p_comm is a fixed-size CChar tuple. Capacity must be a
            // literal here to avoid overlapping access on `entry`.
            let comm = withUnsafePointer(to: &entry.kp_proc.p_comm) { p -> String in
                p.withMemoryRebound(to: CChar.self, capacity: 17) {
                    String(cString: $0)
                }
            }
            procs.append(ProcessInfo_(pid: pid, ppid: ppid,
                                      comm: comm, command: comm))
        }
        return procs
    }
}
