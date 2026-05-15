import BashSyntax
import Foundation

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
