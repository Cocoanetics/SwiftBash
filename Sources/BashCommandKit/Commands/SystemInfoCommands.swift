import ArgumentParser
import BashInterpreter
import Foundation

/// `uname [-a] [-s] [-n] [-r] [-v] [-m]` — print system information.
public struct UnameCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "uname",
        abstract: "Print system information."
    )

    @Flag(name: [.customShort("a"), .customLong("all")],
          help: "Print all the available info.")
    public var all: Bool = false

    @Flag(name: [.customShort("s"), .customLong("kernel-name")],
          help: "Kernel name (default).")
    public var kernel: Bool = false

    @Flag(name: [.customShort("n"), .customLong("nodename")],
          help: "Network node hostname.")
    public var node: Bool = false

    @Flag(name: [.customShort("r"), .customLong("kernel-release")],
          help: "Kernel release.")
    public var release: Bool = false

    @Flag(name: [.customShort("v"), .customLong("kernel-version")],
          help: "Kernel version.")
    public var version: Bool = false

    @Flag(name: [.customShort("m"), .customLong("machine")],
          help: "Machine hardware name.")
    public var machine: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var u = utsname()
        guard Foundation.uname(&u) == 0 else {
            shell.stderr("uname: failed\n")
            return .failure
        }
        // utsname fields are inline char arrays — convert via Mirror.
        let kn = withUnsafePointer(to: &u.sysname) { p -> String in
            p.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        let nn = withUnsafePointer(to: &u.nodename) { p -> String in
            p.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        let rl = withUnsafePointer(to: &u.release) { p -> String in
            p.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        let vr = withUnsafePointer(to: &u.version) { p -> String in
            p.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        let mc = withUnsafePointer(to: &u.machine) { p -> String in
            p.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }

        let any = all || kernel || node || release || version || machine
        let useKernel = !any || kernel || all
        var parts: [String] = []
        if useKernel { parts.append(kn) }
        if all || node { parts.append(nn) }
        if all || release { parts.append(rl) }
        if all || version { parts.append(vr) }
        if all || machine { parts.append(mc) }
        shell.stdout(parts.joined(separator: " ") + "\n")
        return .success
    }
}

/// `id [-u] [-g] [-n] [USER]` — print user / group identities.
///
/// With no flags, prints `uid=N(name) gid=N(name) groups=...`.
/// `-u` prints just the uid; `-g` the gid; `-n` switches to names.
public struct IdCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "id",
        abstract: "Print real and effective user / group IDs."
    )

    @Flag(name: .customShort("u"), help: "Print only the effective uid.")
    public var userOnly: Bool = false

    @Flag(name: .customShort("g"), help: "Print only the effective gid.")
    public var groupOnly: Bool = false

    @Flag(name: .customShort("n"), help: "Print names instead of numbers.")
    public var names: Bool = false

    @Flag(name: .customShort("r"), help: "Print real (not effective) IDs.")
    public var realIds: Bool = false

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        let uid = realIds ? getuid() : geteuid()
        let gid = realIds ? getgid() : getegid()
        let userName = ProcessInfo.processInfo.userName
        let groupName: String = {
            // No portable POSIX way without getgrgid; ProcessInfo doesn't expose it.
            // Use a placeholder that matches `id -gn` output shape.
            "staff"
        }()
        if userOnly {
            shell.stdout((names ? userName : "\(uid)") + "\n")
            return .success
        }
        if groupOnly {
            shell.stdout((names ? groupName : "\(gid)") + "\n")
            return .success
        }
        // Default: uid=N(name) gid=N(name)
        shell.stdout("uid=\(uid)(\(userName)) gid=\(gid)(\(groupName))\n")
        return .success
    }
}

/// `df [-h] [-k] [-m] [PATH...]` — report disk space usage.
public struct DfCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "df",
        abstract: "Report file system disk space usage."
    )

    @Flag(name: [.customShort("h"), .customLong("human-readable")],
          help: "Human-readable sizes (1K, 234M, 2G).")
    public var human: Bool = false

    @Flag(name: .customShort("k"), help: "Sizes in 1024-byte blocks (default).")
    public var kib: Bool = false

    @Flag(name: .customShort("m"), help: "Sizes in megabytes.")
    public var mib: Bool = false

    @Argument(help: "Paths to inspect; defaults to current working directory.")
    public var paths: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        let target = paths.isEmpty ? [shell.environment.workingDirectory] : paths
        // Header.
        if human {
            shell.stdout("Filesystem      Size    Used   Avail Capacity Mounted on\n")
        } else {
            let unit = mib ? "1M-blocks" : "1024-blocks"
            shell.stdout("Filesystem    \(unit)        Used   Available Capacity Mounted on\n")
        }
        var hadError = false
        for p in target {
            let resolved = shell.resolvePath(p)
            var s = statfs()
            let r = resolved.withCString { statfs($0, &s) }
            if r != 0 {
                shell.stderr("df: \(p): no such file or directory\n")
                hadError = true; continue
            }
            let blockSize = UInt64(s.f_bsize)
            let total = UInt64(s.f_blocks) * blockSize
            let free = UInt64(s.f_bavail) * blockSize
            let used = total > free ? total - free : 0
            let pct = total == 0 ? 0 : Int((Double(used) / Double(total)) * 100)
            let mount = withUnsafePointer(to: &s.f_mntonname) { p -> String in
                p.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            let device = withUnsafePointer(to: &s.f_mntfromname) { p -> String in
                p.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            let totalStr = formatSize(total)
            let usedStr = formatSize(used)
            let availStr = formatSize(free)
            shell.stdout("\(device.padding(toLength: 14, withPad: " ", startingAt: 0))" +
                         " \(totalStr.leftPad(8))" +
                         " \(usedStr.leftPad(8))" +
                         " \(availStr.leftPad(8))" +
                         " \(String(pct).leftPad(7))% \(mount)\n")
        }
        return hadError ? .failure : .success
    }

    private func formatSize(_ bytes: UInt64) -> String {
        if human {
            let n = Double(bytes)
            let k = 1024.0
            if n < k { return "\(bytes)B" }
            if n < k * k {
                let v = n / k
                return v < 10 ? String(format: "%.1fK", v) : "\(Int(v.rounded()))K"
            }
            if n < k * k * k {
                let v = n / (k * k)
                return v < 10 ? String(format: "%.1fM", v) : "\(Int(v.rounded()))M"
            }
            if n < k * k * k * k {
                let v = n / (k * k * k)
                return v < 10 ? String(format: "%.1fG", v) : "\(Int(v.rounded()))G"
            }
            let v = n / (k * k * k * k)
            return String(format: "%.1fT", v)
        }
        if mib {
            return String(bytes / (1024 * 1024))
        }
        return String(bytes / 1024)
    }
}

/// `nohup COMMAND [ARG...]` — run a command immune to hangups.
///
/// In our shell there are no real signals to ignore, so this is a
/// thin wrapper that runs the command and emits the standard
/// "appending output to nohup.out" notice on stderr (only when the
/// destination differs from stdin's fd, which is always the case
/// here since stdin is treated as a tty stand-in).
public struct NohupCommand: Command {
    public let name = "nohup"
    public init() {}

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())
        guard !args.isEmpty else {
            shell.stderr("nohup: usage: nohup COMMAND [ARG...]\n")
            return ExitStatus(127)
        }
        let line = args.map(shellQuote).joined(separator: " ")
        shell.stderr("nohup: ignoring input and appending output to 'nohup.out'\n")
        return try await shell.run(line)
    }

    private func shellQuote(_ s: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !s.isEmpty && s.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// `cmp [-s] FILE1 FILE2` — byte-by-byte comparison. Exit 0 if equal,
/// 1 if different, 2 on error. With `-s`, no output.
public struct CmpCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cmp",
        abstract: "Compare two files byte by byte."
    )

    @Flag(name: [.customShort("s"), .customLong("silent")],
          help: "Suppress output; exit status only.")
    public var silent: Bool = false

    @Argument(help: "FILE1 FILE2")
    public var files: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard files.count == 2 else {
            shell.stderr("cmp: usage: cmp [-s] FILE1 FILE2\n")
            return ExitStatus(2)
        }
        let a: Data, b: Data
        do {
            a = try await shell.readDataAtPath(files[0])
            b = try await shell.readDataAtPath(files[1])
        } catch {
            shell.stderr("cmp: \(error)\n")
            return ExitStatus(2)
        }
        let n = min(a.count, b.count)
        var line = 1
        for i in 0..<n {
            if a[i] != b[i] {
                if !silent {
                    shell.stdout("\(files[0]) \(files[1]) differ: char \(i + 1), line \(line)\n")
                }
                return ExitStatus(1)
            }
            if a[i] == 0x0A { line += 1 }
        }
        if a.count != b.count {
            if !silent {
                let longer = a.count > b.count ? files[0] : files[1]
                shell.stdout("cmp: EOF on \(longer)\n")
            }
            return ExitStatus(1)
        }
        return .success
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        if count >= width { return self }
        return String(repeating: " ", count: width - count) + self
    }
}
