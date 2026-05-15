import ArgumentParser
import BashCommandKit
import BashInterpreter
import BashSyntax
import Foundation

struct UsageScriptRecord {
    let filePath: String
    let lineNumber: Int
    let script: String
}

struct UsageCommandInvocation {
    let command: String
    let options: [String]
}

struct UsageSignature: Hashable {
    let command: String
    let options: [String]
}

struct UsageRow {
    let command: String
    let options: [String]
    let count: Int
    let isCovered: Bool
}

struct UsageReport {
    let sourceName: String
    let sessionFileCount: Int
    let bashToolCallCount: Int
    let bashScriptCount: Int
    let parsedScriptCount: Int
    let parseFailureCount: Int
    let commandInvocationCount: Int
    let coveredInvocationCount: Int
    let uniqueCommandCount: Int
    let coveredUniqueCommandCount: Int
    let commandRows: [UsageRow]
    let signatureRows: [UsageRow]
}

enum UsageReportPrinter {
    static func validate(top: Int, minCount: Int) throws {
        guard top > 0 else {
            throw ValidationError("--top must be greater than 0.")
        }
        guard minCount > 0 else {
            throw ValidationError("--min-count must be greater than 0.")
        }
    }

    // swiftlint:disable:next function_body_length - 4 sections of printable output
    static func print(_ report: UsageReport, top: Int, minCount: Int, missingOnly: Bool) {
        Swift.print("Source: \(report.sourceName)")
        Swift.print("Scanned \(report.sessionFileCount) session file(s).")
        Swift.print(
            "Found \(report.bashToolCallCount) bash tool call(s) containing "
            + "\(report.bashScriptCount) script payload(s).")
        Swift.print(
            "Parsed \(report.parsedScriptCount) script(s) into "
            + "\(report.commandInvocationCount) command invocation(s).")
        if report.parseFailureCount > 0 {
            Swift.print("Skipped \(report.parseFailureCount) script(s) that did not parse cleanly.")
        }
        Swift.print("")

        Swift.print("Coverage")
        Swift.print(
            "  Weighted: \(report.coveredInvocationCount)/\(report.commandInvocationCount) "
            + "invocations (\(percent(report.coveredInvocationCount, report.commandInvocationCount)))")
        Swift.print(
            "  Unique:   \(report.coveredUniqueCommandCount)/\(report.uniqueCommandCount) "
            + "commands (\(percent(report.coveredUniqueCommandCount, report.uniqueCommandCount)))")
        Swift.print("")

        printSection(
            title: "Top Commands",
            rows: report.commandRows,
            top: top,
            minCount: minCount,
            missingOnly: missingOnly
        )
        Swift.print("")
        printSection(
            title: "Top Commands With Options",
            rows: report.signatureRows.filter { !$0.options.isEmpty },
            top: top,
            minCount: minCount,
            missingOnly: missingOnly
        )
        Swift.print("")
        printSection(
            title: "Top Missing Commands",
            rows: report.commandRows.filter { !$0.isCovered },
            top: top,
            minCount: minCount,
            missingOnly: false
        )
        Swift.print("")
        printSection(
            title: "Top Missing Commands With Options",
            rows: report.signatureRows.filter { !$0.isCovered && !$0.options.isEmpty },
            top: top,
            minCount: minCount,
            missingOnly: false
        )
    }

    private static func printSection(
        title: String,
        rows: [UsageRow],
        top: Int,
        minCount: Int,
        missingOnly: Bool
    ) {
        let filtered = rows
            .filter { $0.count >= minCount }
            .filter { !missingOnly || !$0.isCovered }
            .prefix(top)

        Swift.print(title)
        if filtered.isEmpty {
            Swift.print("  (none)")
            return
        }

        for row in filtered {
            let coverage = row.isCovered ? "covered" : "missing"
            let optionsSuffix = row.options.isEmpty ? "" : " [\(row.options.joined(separator: " "))]"
            Swift.print("  \(row.count)\t\(coverage)\t\(row.command)\(optionsSuffix)")
        }
    }

    private static func percent(_ numerator: Int, _ denominator: Int) -> String {
        guard denominator > 0 else { return "0.0%" }
        let value = (Double(numerator) / Double(denominator)) * 100
        return String(format: "%.1f%%", value)
    }
}

enum UsageSupport {
    /// Tool names that LLM agents (Codex, Claude, …) call *through*
    /// bash but that aren't real POSIX utilities — they're the
    /// agent's own in-process helpers being shelled to. Excluded
    /// from the coverage report because we'd never implement them
    /// and they otherwise dominate the "missing commands" list.
    ///
    /// Add to this list when you spot a new agent-internal tool
    /// being invoked via `bash -lc "<tool> …"`.
    static let agentInternalCommands: Set<String> = [
        "apply_patch", "applypatch"   // Codex file-edit helper
    ]

    static func sessionFiles(rootPath: String) -> [URL] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard ["jsonal", "jsonl"].contains(url.pathExtension.lowercased()) else {
                continue
            }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }

            files.append(url)
        }

        return files.sorted { $0.path < $1.path }
    }

    static func parseJSONLine(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decodeNestedJSON(from value: Any?) -> Any? {
        guard let value else { return nil }
        if let string = value as? String, let data = string.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data)) ?? string
        }
        return value
    }

    static func supportedCommandCoverage() -> Set<String> {
        // Construct a fresh shell, register the kit's standard
        // commands directly on it, and union with the language
        // built-ins to get the full set of names a real script can
        // call. (Earlier this read `Shell.bashCurrent` which is the
        // never-bound placeholder — bug; the registration ran on the
        // wrong shell and the local was unused, hence the warning.)
        let shell = Shell()
        shell.registerStandardCommands()
        return Set(Shell.defaultCommands().keys).union(shell.commands.keys)
    }

    static func rowComparator(_ lhs: UsageRow, _ rhs: UsageRow) -> Bool {
        if lhs.count != rhs.count {
            return lhs.count > rhs.count
        }
        if lhs.command != rhs.command {
            return lhs.command < rhs.command
        }
        return lhs.options.joined(separator: "\u{1F}") < rhs.options.joined(separator: "\u{1F}")
    }

    // swiftlint:disable:next function_body_length - aggregates several counters and row tables
    static func buildReport(sourceName: String, scripts: [UsageScriptRecord], contains: String?) -> UsageReport {
        let supportedCommands = supportedCommandCoverage()

        var parsedScriptCount = 0
        var parseFailureCount = 0
        var invocations: [UsageCommandInvocation] = []
        var matchedScripts = 0

        for script in scripts {
            guard contains == nil || script.script.localizedCaseInsensitiveContains(contains!) else {
                continue
            }

            matchedScripts += 1

            do {
                let nodes = try BashSyntax.parse(script.script)
                parsedScriptCount += 1
                var collector = CommandCollector()
                for node in nodes {
                    node.walk(&collector)
                }
                // Filter out agent-internal tool calls. Codex shells out
                // to `apply_patch` (its in-process file-editing helper)
                // by piping a heredoc into a bash invocation; the parser
                // correctly sees it as a bash command, but it isn't a
                // POSIX utility we'd ever implement and including it
                // pollutes the coverage report with hundreds of "missing"
                // rows for what's really one Codex tool.
                let filtered = collector.invocations.filter {
                    !Self.agentInternalCommands.contains($0.command)
                }
                invocations.append(contentsOf: filtered)
            } catch {
                parseFailureCount += 1
            }
        }

        let commandCounts = Dictionary(invocations.map { ($0.command, 1) }, uniquingKeysWith: +)
        let signatureCounts = Dictionary(
            invocations.map { (UsageSignature(command: $0.command, options: $0.options), 1) },
            uniquingKeysWith: +
        )

        let commandRows = commandCounts
            .map { command, count in
                UsageRow(command: command, options: [], count: count, isCovered: supportedCommands.contains(command))
            }
            .sorted(by: rowComparator)

        let signatureRows = signatureCounts
            .map { key, count in
                UsageRow(
                    command: key.command,
                    options: key.options,
                    count: count,
                    isCovered: supportedCommands.contains(key.command)
                )
            }
            .sorted(by: rowComparator)

        let coveredInvocationCount = invocations.reduce(into: 0) { partial, invocation in
            if supportedCommands.contains(invocation.command) {
                partial += 1
            }
        }

        let uniqueCommands = Set(invocations.map(\.command))
        let coveredUniqueCommandCount = uniqueCommands.intersection(supportedCommands).count

        let sessionFiles = Set(scripts.map(\.filePath)).count

        return UsageReport(
            sourceName: sourceName,
            sessionFileCount: sessionFiles,
            bashToolCallCount: matchedScripts,
            bashScriptCount: matchedScripts,
            parsedScriptCount: parsedScriptCount,
            parseFailureCount: parseFailureCount,
            commandInvocationCount: invocations.count,
            coveredInvocationCount: coveredInvocationCount,
            uniqueCommandCount: uniqueCommands.count,
            coveredUniqueCommandCount: coveredUniqueCommandCount,
            commandRows: commandRows,
            signatureRows: signatureRows
        )
    }
}

// `CodexUsageAnalyzer` and `ClaudeUsageAnalyzer` live in `UsageAnalyzers.swift`.
// `CommandCollector` lives in `UsageCommandCollector.swift`.
