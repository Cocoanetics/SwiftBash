import ArgumentParser
import BashInterpreter
import Foundation

/// `df [-h] [-k] [-m] [PATH...]` — report disk space usage.
///
/// **Virtual.** Reports a single synthetic filesystem entry per path:
/// the filesystem name comes from ``Shell/hostInfo`` (default
/// `"sandbox"`) and a single mount point representing whichever
/// ``Shell/fileSystem`` the path lives on. The host's `statfs(2)` is
/// never called — a script can't enumerate or sniff the host's
/// real disk layout.
///
/// Sizes are *not* reported because a virtual file system has no
/// meaningful "total" / "free" — we'd have to fabricate numbers.
/// We print `-` for unknowns so script consumers parsing column
/// positions still work.
public struct DfCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "df",
        abstract: "Report file system usage (virtual)."
    )

    @Flag(name: [.customShort("h"), .customLong("human-readable")],
          help: "Human-readable sizes (no-op in virtual mode).")
    public var human: Bool = false

    @Flag(name: .customShort("k"), help: "Sizes in 1024-byte blocks (default).")
    public var kib: Bool = false

    @Flag(name: .customShort("m"), help: "Sizes in megabytes.")
    public var mib: Bool = false

    @Argument(help: "Paths to inspect; defaults to current working directory.")
    public var paths: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let target = paths.isEmpty
            ? [Shell.bashCurrent.environment.workingDirectory] : paths
        if human {
            Shell.bashCurrent.stdout(
                "Filesystem      Size    Used   Avail Capacity Mounted on\n")
        } else {
            let unit = mib ? "1M-blocks" : "1024-blocks"
            Shell.bashCurrent.stdout(
                "Filesystem    \(unit)        Used   Available Capacity Mounted on\n")
        }
        let host = Shell.bashCurrent.hostInfo
        let label = host.hostName.padding(toLength: 14,
                                          withPad: " ", startingAt: 0)
        var hadError = false
        for path in target {
            let resolved = Shell.bashCurrent.resolvePath(path)
            // Confirm the path actually exists in the shell's
            // filesystem before reporting.
            guard (try? await Shell.bashCurrent.fileSystem.metadata(resolved)) != nil
            else {
                Shell.bashCurrent.stderr("df: \(path): no such file or directory\n")
                hadError = true; continue
            }
            // Sizes unknown for a virtual mount; emit `-` placeholders
            // so column-parsing consumers still split correctly.
            Shell.bashCurrent.stdout(
                "\(label)" +
                " \("-".leftPad(8))" +
                " \("-".leftPad(8))" +
                " \("-".leftPad(8))" +
                " \("-".leftPad(7))% \(resolved)\n")
        }
        return hadError ? .failure : .success
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        if count >= width { return self }
        return String(repeating: " ", count: width - count) + self
    }
}
