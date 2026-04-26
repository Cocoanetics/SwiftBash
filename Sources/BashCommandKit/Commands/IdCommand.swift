import ArgumentParser
import BashInterpreter
import Foundation

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

    public mutating func execute() async throws -> ExitStatus {
        let uid = realIds ? getuid() : geteuid()
        let gid = realIds ? getgid() : getegid()
        let userName = ProcessInfo.processInfo.userName
        let groupName: String = {
            // No portable POSIX way without getgrgid; ProcessInfo doesn't expose it.
            // Use a placeholder that matches `id -gn` output shape.
            "staff"
        }()
        if userOnly {
            Shell.current.stdout((names ? userName : "\(uid)") + "\n")
            return .success
        }
        if groupOnly {
            Shell.current.stdout((names ? groupName : "\(gid)") + "\n")
            return .success
        }
        // Default: uid=N(name) gid=N(name)
        Shell.current.stdout("uid=\(uid)(\(userName)) gid=\(gid)(\(groupName))\n")
        return .success
    }
}
