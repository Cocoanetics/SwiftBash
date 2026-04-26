import ArgumentParser
import BashInterpreter
import Foundation

/// `hostname` — print the machine's host name.
public struct HostnameCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hostname",
        abstract: "Print the host name of the machine."
    )

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        Shell.current.stdout(ProcessInfo.processInfo.hostName + "\n")
        return .success
    }
}
