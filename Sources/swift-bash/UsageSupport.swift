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

    static func print(_ report: UsageReport, top: Int, minCount: Int, missingOnly: Bool) {
        Swift.print("Source: \(report.sourceName)")
        Swift.print("Scanned \(report.sessionFileCount) session file(s).")
        Swift.print("Found \(report.bashToolCallCount) bash tool call(s) containing \(report.bashScriptCount) script payload(s).")
        Swift.print("Parsed \(report.parsedScriptCount) script(s) into \(report.commandInvocationCount) command invocation(s).")
        if report.parseFailureCount > 0 {
            Swift.print("Skipped \(report.parseFailureCount) script(s) that did not parse cleanly.")
        }
        Swift.print("")

        Swift.print("Coverage")
        Swift.print("  Weighted: \(report.coveredInvocationCount)/\(report.commandInvocationCount) invocations (\(percent(report.coveredInvocationCount, report.commandInvocationCount)))")
        Swift.print("  Unique:   \(report.coveredUniqueCommandCount)/\(report.uniqueCommandCount) commands (\(percent(report.coveredUniqueCommandCount, report.uniqueCommandCount)))")
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
        let builtinCommands = Set(Shell.defaultCommands().keys)
        let shell = Shell()
        Shell.current.registerStandardCommands()
        return builtinCommands.union(Shell.current.commands.keys)
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
                invocations.append(contentsOf: collector.invocations)
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

struct CodexUsageAnalyzer {
    let rootPath: String
    let contains: String?

    func run() throws -> UsageReport {
        let files = UsageSupport.sessionFiles(rootPath: rootPath)
        let scripts = files.flatMap(readScripts)
        return UsageSupport.buildReport(sourceName: "Codex", scripts: scripts, contains: contains)
    }

    private func readScripts(from fileURL: URL) -> [UsageScriptRecord] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        var scripts: [UsageScriptRecord] = []
        for (offset, line) in contents.split(whereSeparator: \.isNewline).enumerated() {
            guard let object = UsageSupport.parseJSONLine(line) else { continue }
            guard let script = extractScript(from: object) else { continue }
            scripts.append(UsageScriptRecord(
                filePath: fileURL.path,
                lineNumber: offset + 1,
                script: script
            ))
        }
        return scripts
    }

    private func extractScript(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "response_item" else { return nil }
        guard let payload = object["payload"] as? [String: Any] else { return nil }

        let payloadType = payload["type"] as? String
        let supportedTypes = Set(["function_call", "custom_tool_call"])
        guard let payloadType, supportedTypes.contains(payloadType) else { return nil }

        return bashScript(in: payload)
    }

    private func bashScript(in value: Any?) -> String? {
        guard let value = UsageSupport.decodeNestedJSON(from: value) else { return nil }

        if let array = value as? [Any], array.count >= 3 {
            let executable = String(describing: array[0])
            let flag = String(describing: array[1])
            if URL(fileURLWithPath: executable).lastPathComponent == "bash",
               (flag == "-lc" || flag == "-c"),
               let script = array[2] as? String {
                return script
            }
        }

        if let dictionary = value as? [String: Any] {
            for key in ["arguments", "input", "command", "cmd"] {
                if let match = bashScript(in: dictionary[key]) {
                    return match
                }
            }

            for (_, nested) in dictionary {
                if let match = bashScript(in: nested) {
                    return match
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let match = bashScript(in: item) {
                    return match
                }
            }
        }

        return nil
    }
}

struct ClaudeUsageAnalyzer {
    let rootPath: String
    let contains: String?

    func run() throws -> UsageReport {
        let files = UsageSupport.sessionFiles(rootPath: rootPath)
        let scripts = files.flatMap(readScripts)
        return UsageSupport.buildReport(sourceName: "Claude", scripts: scripts, contains: contains)
    }

    private func readScripts(from fileURL: URL) -> [UsageScriptRecord] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        var scripts: [UsageScriptRecord] = []
        for (offset, line) in contents.split(whereSeparator: \.isNewline).enumerated() {
            guard let object = UsageSupport.parseJSONLine(line) else { continue }
            guard let script = extractScript(from: object) else { continue }
            scripts.append(UsageScriptRecord(
                filePath: fileURL.path,
                lineNumber: offset + 1,
                script: script
            ))
        }
        return scripts
    }

    private func extractScript(from object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        guard message["role"] as? String == "assistant" else { return nil }
        guard let content = message["content"] as? [[String: Any]] else { return nil }

        for item in content {
            guard item["type"] as? String == "tool_use" else { continue }
            guard item["name"] as? String == "Bash" else { continue }
            guard let input = item["input"] as? [String: Any],
                  let command = input["command"] as? String else {
                continue
            }
            return command
        }

        return nil
    }
}

struct CommandCollector: NodeVisitor {
    var invocations: [UsageCommandInvocation] = []

    mutating func visitCommand(_ node: Node, parts: [Node]) -> Bool {
        if let invocation = extractInvocation(from: parts) {
            invocations.append(invocation)
        }
        return true
    }

    private func extractInvocation(from parts: [Node]) -> UsageCommandInvocation? {
        let words = parts.compactMap(extractWord)
        guard !words.isEmpty else { return nil }

        var commandWord: String?
        var options: [String] = []
        var sawDoubleDash = false

        for word in words {
            if commandWord == nil {
                if isAssignment(word) {
                    continue
                }
                commandWord = canonicalCommandName(from: word)
                if commandWord == nil {
                    return nil
                }
                continue
            }

            if sawDoubleDash {
                continue
            }

            if word == "--" {
                sawDoubleDash = true
                options.append(word)
                continue
            }

            if isOption(word) {
                options.append(word)
            }
        }

        guard let commandWord else { return nil }
        return .init(command: commandWord, options: options)
    }

    private func extractWord(from node: Node) -> String? {
        switch node.kind {
        case .word(let word, _):
            return word
        case .assignment(let word, _):
            return word
        default:
            return nil
        }
    }

    private func isAssignment(_ word: String) -> Bool {
        guard !word.hasPrefix("-"), !word.hasPrefix("/"), !word.contains(" ") else {
            return false
        }

        guard let equalsIndex = word.firstIndex(of: "=") else { return false }
        let name = String(word[..<equalsIndex])
        guard !name.isEmpty else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func isOption(_ word: String) -> Bool {
        guard word.count > 1, word.hasPrefix("-") else { return false }
        return word != "-" && !looksNumeric(word)
    }

    private func looksNumeric(_ word: String) -> Bool {
        Double(word) != nil
    }

    private func canonicalCommandName(from word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("/")
            ? URL(fileURLWithPath: trimmed).lastPathComponent
            : trimmed

        guard isPlausibleCommandName(candidate) else { return nil }
        return candidate
    }

    private func isPlausibleCommandName(_ word: String) -> Bool {
        if ["[", "]", ".", ":"].contains(word) {
            return true
        }

        guard let first = word.first else { return false }
        guard first.isLetter || first.isNumber || first == "_" else { return false }

        return word.allSatisfy { character in
            character.isLetter
                || character.isNumber
                || character == "_"
                || character == "-"
                || character == "."
                || character == "+"
        }
    }
}
