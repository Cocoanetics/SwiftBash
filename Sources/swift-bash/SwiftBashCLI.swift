import ArgumentParser

/// Top-level `swift-bash` command. Dispatches to subcommands.
@main
struct SwiftBashCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-bash",
        abstract: "Command-line tools for working with bash source.",
        version: "0.1.0",
        subcommands: [ParseCommand.self, ExecCommand.self, CodexUsageCommand.self, ClaudeUsageCommand.self]
    )
}
