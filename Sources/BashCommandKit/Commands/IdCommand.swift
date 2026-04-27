import ArgumentParser
import BashInterpreter
import Foundation

/// `id [-u] [-g] [-n] [-G] [USER]` — print user / group identities.
///
/// With no flags, prints `uid=N(name) gid=N(name) groups=...`.
/// `-u` prints just the uid; `-g` the gid; `-G` all group ids;
/// `-n` switches to names. All values come from
/// ``Shell/hostInfo`` — never the real `getuid()` / `getgid()`
/// syscalls — so a sandboxed script can't enumerate the real user.
public struct IdCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "id",
        abstract: "Print user / group IDs."
    )

    @Flag(name: .customShort("u"), help: "Print only the effective uid.")
    public var userOnly: Bool = false

    @Flag(name: .customShort("g"), help: "Print only the effective gid.")
    public var groupOnly: Bool = false

    @Flag(name: .customShort("G"), help: "Print all group ids.")
    public var allGroups: Bool = false

    @Flag(name: .customShort("n"), help: "Print names instead of numbers.")
    public var names: Bool = false

    @Flag(name: .customShort("r"), help: "Print real (not effective) IDs.")
    public var realIds: Bool = false

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let host = Shell.current.hostInfo
        let uid = host.uid
        let gid = host.gid

        if userOnly {
            Shell.current.stdout((names ? host.userName : "\(uid)") + "\n")
            return .success
        }
        if groupOnly {
            Shell.current.stdout((names ? host.groupName : "\(gid)") + "\n")
            return .success
        }
        if allGroups {
            let parts = host.groups.map { names ? host.groupName : "\($0)" }
            Shell.current.stdout(parts.joined(separator: " ") + "\n")
            return .success
        }
        // Default: uid=N(name) gid=N(name) groups=N(name),M(...)
        let groupsField = host.groups
            .map { "\($0)(\(host.groupName))" }
            .joined(separator: ",")
        Shell.current.stdout(
            "uid=\(uid)(\(host.userName)) gid=\(gid)(\(host.groupName))"
            + " groups=\(groupsField)\n")
        return .success
    }
}
