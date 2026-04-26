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

    public mutating func execute() async throws -> ExitStatus {
        var u = utsname()
        guard Foundation.uname(&u) == 0 else {
            Shell.current.stderr("uname: failed\n")
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
        Shell.current.stdout(parts.joined(separator: " ") + "\n")
        return .success
    }
}
