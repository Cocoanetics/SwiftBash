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

    public mutating func execute(shell: Shell) throws -> ExitStatus {
        if n <= 0 { return .success }
        var out = ""
        var lineCount = 0
        for ch in shell.stdin {
            out.append(ch)
            if ch == "\n" {
                lineCount += 1
                if lineCount >= n { break }
            }
        }
        shell.stdout(out)
        return .success
    }
}
