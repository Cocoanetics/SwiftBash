import ArgumentParser
import BashInterpreter
import Foundation

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

    public mutating func execute() async throws -> ExitStatus {
        let target = paths.isEmpty ? [Shell.current.environment.workingDirectory] : paths
        // Header.
        if human {
            Shell.current.stdout("Filesystem      Size    Used   Avail Capacity Mounted on\n")
        } else {
            let unit = mib ? "1M-blocks" : "1024-blocks"
            Shell.current.stdout("Filesystem    \(unit)        Used   Available Capacity Mounted on\n")
        }
        var hadError = false
        for p in target {
            let resolved = Shell.current.resolvePath(p)
            var s = statfs()
            let r = resolved.withCString { statfs($0, &s) }
            if r != 0 {
                Shell.current.stderr("df: \(p): no such file or directory\n")
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
            Shell.current.stdout("\(device.padding(toLength: 14, withPad: " ", startingAt: 0))" +
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

private extension String {
    func leftPad(_ width: Int) -> String {
        if count >= width { return self }
        return String(repeating: " ", count: width - count) + self
    }
}
