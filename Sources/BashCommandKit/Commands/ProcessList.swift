import Foundation

/// Parse a signal name (with or without the `SIG` prefix) or a numeric
/// signal value into the corresponding signal number. Used by `kill`
/// and `pkill` to interpret `-TERM` / `-9` / `-SIGINT` arguments.
///
/// In SwiftBash these signal numbers are advisory — every signal maps
/// to `Task.cancel()` on the target virtual job. Real POSIX signals
/// are never delivered.
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
