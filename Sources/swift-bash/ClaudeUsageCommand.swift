import ArgumentParser
import BashCommandKit
import BashInterpreter
import BashSyntax
import Foundation

struct ClaudeUsageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-usage",
        abstract: "Analyze command and option usage across Claude session logs."
    )

    @Option(name: [.short, .long],
            help: "Root directory to scan for Claude project logs.")
    var root: String = "~/.claude/projects"

    @Option(name: .long,
            help: "Only include bash scripts containing this text before parsing.")
    var contains: String?

    @Option(name: .long,
            help: "How many rows to print in each ranking section.")
    var top: Int = 20

    @Option(name: .long,
            help: "Suppress rows below this count.")
    var minCount: Int = 1

    @Flag(name: .long,
          help: "Print only commands not covered by the current SwiftBash command set.")
    var missingOnly = false

    func validate() throws {
        try UsageReportPrinter.validate(top: top, minCount: minCount)
    }

    func run() throws {
        // Expand `~` against the host's home so the default works
        // for any user without baking a username into the binary.
        let resolvedRoot = (root as NSString).expandingTildeInPath
        let analyzer = ClaudeUsageAnalyzer(rootPath: resolvedRoot,
                                           contains: contains)
        let report = try analyzer.run()
        UsageReportPrinter.print(report, top: top, minCount: minCount, missingOnly: missingOnly)
    }
}
