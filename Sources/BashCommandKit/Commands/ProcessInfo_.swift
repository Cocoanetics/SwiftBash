import ArgumentParser
import BashInterpreter
import Foundation

/// Per-process snapshot used by `ps` / `pgrep` / `pkill`.
struct ProcessInfo_ {
    let pid: Int32
    let ppid: Int32
    let comm: String     // short name
    let command: String  // full path or argv[0]
}
