import ArgumentParser
import BashInterpreter
import Foundation

/// `uname [-a] [-s] [-n] [-r] [-v] [-m]` — print system information.
///
/// All values come from ``Shell/hostInfo`` (synthetic by default).
/// The host's `uname(2)` is never consulted.
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

    public mutating func execute() async throws -> ExitStatus {
        let host = Shell.current.hostInfo
        let any = all || kernel || node || release || version || machine
        let useKernel = !any || kernel || all
        var parts: [String] = []
        if useKernel       { parts.append(host.kernelName) }
        if all || node     { parts.append(host.nodeName) }
        if all || release  { parts.append(host.kernelRelease) }
        if all || version  { parts.append(host.kernelVersion) }
        if all || machine  { parts.append(host.machine) }
        Shell.current.stdout(parts.joined(separator: " ") + "\n")
        return .success
    }
}
