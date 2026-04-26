import ArgumentParser
import BashInterpreter
import Foundation

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
func parseSignal(_ s: String) -> Int32? {
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

