import ArgumentParser
import BashInterpreter

/// `groups [USER]` — print the groups the user belongs to.
///
/// With no argument, prints the running shell's effective groups
/// from ``HostInfo``. With a USER argument, only `whoami`'s name
/// is recognised — any other name reports `unknown user`. We don't
/// have a multi-user database, so per-user lookups are limited to
/// the synthetic identity.
public struct GroupsCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "Print the groups a user belongs to."
    )

    @Argument(help: "User to look up; defaults to the current user.")
    public var users: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let host = Shell.bashCurrent.hostInfo
        let names = users.isEmpty ? [host.userName] : users
        var hadError = false
        for name in names {
            guard name == host.userName else {
                Shell.bashCurrent.stderr("groups: \(name): unknown user\n")
                hadError = true
                continue
            }
            // We only know the primary group's name. Supplementary
            // groups are reported by GID since we have no name table.
            var line: [String] = [host.groupName]
            for gid in host.groups where gid != host.gid {
                line.append("\(gid)")
            }
            Shell.bashCurrent.stdout(line.joined(separator: " ") + "\n")
        }
        return hadError ? .failure : .success
    }
}
