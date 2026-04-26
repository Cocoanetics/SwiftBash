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

    public mutating func execute() async throws -> ExitStatus {
        if seconds < 0 {
            Shell.current.stderr("sleep: negative duration\n")
            return .failure
        }
        if seconds > 0 {
            // Cooperative sleep: doesn't pin a thread, responds to
            // Task cancellation — so a downstream pipeline stage
            // finishing early can actually unblock us.
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        return .success
    }
}
