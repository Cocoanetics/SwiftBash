import Foundation

#if os(Windows)
let SIGHUP:  Int32 = 1
let SIGQUIT: Int32 = 3
let SIGTRAP: Int32 = 5
let SIGKILL: Int32 = 9
let SIGBUS:  Int32 = 10
let SIGUSR1: Int32 = 30
let SIGUSR2: Int32 = 31
let SIGSYS:  Int32 = 12
let SIGPIPE: Int32 = 13
let SIGALRM: Int32 = 14
let SIGURG:  Int32 = 16
let SIGSTOP: Int32 = 17
let SIGTSTP: Int32 = 18
let SIGCONT: Int32 = 19
let SIGCHLD: Int32 = 20
let SIGTTIN: Int32 = 21
let SIGTTOU: Int32 = 22
#endif

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
