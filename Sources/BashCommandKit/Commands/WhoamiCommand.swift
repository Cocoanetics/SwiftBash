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

    public mutating func execute(shell: Shell) throws -> ExitStatus {
        shell.stdout(ProcessInfo.processInfo.userName + "\n")
        return .success
    }
}
