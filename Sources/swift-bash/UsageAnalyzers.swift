import Foundation

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

    // swiftlint:disable:next cyclomatic_complexity - recursive shape matcher
    private func bashScript(in value: Any?) -> String? {
        guard let value = UsageSupport.decodeNestedJSON(from: value) else { return nil }

        if let array = value as? [Any], array.count >= 3 {
            let executable = String(describing: array[0])
            let flag = String(describing: array[1])
            if URL(fileURLWithPath: executable).lastPathComponent == "bash",
               flag == "-lc" || flag == "-c",
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
