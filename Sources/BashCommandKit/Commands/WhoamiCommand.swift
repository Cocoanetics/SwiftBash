import ArgumentParser
import BashInterpreter
import Foundation

/// `whoami` — print the current user name.
public struct WhoamiCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "whoami",
        abstract: "Print the effective user name."
    )

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        // Read from the shell's `HostInfo` (synthetic by default).
        // Never queries the host process for the real user name.
        Shell.bashCurrent.stdout(Shell.bashCurrent.hostInfo.userName + "\n")
        return .success
    }
}
