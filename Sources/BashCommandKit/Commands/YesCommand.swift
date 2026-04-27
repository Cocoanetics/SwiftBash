import ArgumentParser
import BashInterpreter

/// `yes [STRING...]` — print STRING (or `y`) repeatedly until
/// killed. Useful as the producing side of a pipe when you need to
/// answer interactive prompts (`yes | rm -i …`) or generate test
/// load.
///
/// The loop honours cooperative cancellation: the consumer ending
/// (`yes | head` exiting after the head is full) cancels the
/// upstream task, which exits the loop here.
public struct YesCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "yes",
        abstract: "Print a string repeatedly until killed."
    )

    @Argument(help: "Strings to print on each line; defaults to 'y'.")
    public var words: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let line = (words.isEmpty ? "y" : words.joined(separator: " ")) + "\n"
        // Tight loop with periodic cancellation checks. We don't
        // sleep — `head` and friends drain quickly enough that
        // cancellation latency stays under a millisecond.
        while true {
            try Task.checkCancellation()
            Shell.current.stdout(line)
        }
    }
}
