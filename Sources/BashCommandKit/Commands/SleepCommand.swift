import ArgumentParser
import BashInterpreter
import Foundation

/// `sleep SECONDS` — pause for the given (possibly fractional) duration.
///
/// ```
/// sleep 1
/// sleep 0.25
/// ```
public struct SleepCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sleep",
        abstract: "Pause for a given number of seconds."
    )

    @Argument(help: "Duration in seconds (fractions allowed).")
    public var seconds: Double

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        if seconds < 0 {
            shell.stderr("sleep: negative duration\n")
            return .failure
        }
        if seconds > 0 {
            Thread.sleep(forTimeInterval: seconds)
        }
        return .success
    }
}
