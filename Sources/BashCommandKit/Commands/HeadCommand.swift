import ArgumentParser
import BashInterpreter

/// `head [-n N]` — copy the first N lines of stdin (default 10) to stdout.
public struct HeadCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "head",
        abstract: "Print the first N lines of stdin."
    )

    @Option(name: [.short, .long],
            help: ArgumentHelp("Number of lines to print.", valueName: "N"))
    public var n: Int = 10

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        if n <= 0 { return .success }
        // Stream lines as they arrive so that `head` can trigger the
        // upstream's cancellation as soon as it has enough — in a
        // streaming pipeline this is how `yes | head` terminates.
        var emitted = 0
        for await line in shell.stdin.lines {
            shell.stdout(line + "\n")
            emitted += 1
            if emitted >= n { break }
        }
        return .success
    }
}
