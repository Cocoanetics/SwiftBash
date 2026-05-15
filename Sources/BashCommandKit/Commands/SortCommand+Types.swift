import Foundation

// MARK: - Options & key spec types

struct SortOptions {
    var reverse = false
    var numeric = false
    var unique = false
    var ignoreCase = false
    var humanNumeric = false
    var versionSort = false
    var dictionaryOrder = false
    var monthSort = false
    var ignoreLeadingBlanks = false
    var stable = false
    var checkOnly = false
    var outputFile: String?
    var keys: [KeySpec] = []
    var fieldDelimiter: String?
}

struct KeySpec {
    var startField: Int = 1
    var startChar: Int?
    var endField: Int?
    var endChar: Int?
    var numeric: Bool?
    var reverse: Bool?
    var ignoreCase: Bool?
    var ignoreLeading: Bool?
    var humanNumeric: Bool?
    var versionSort: Bool?
    var dictionaryOrder: Bool?
    var monthSort: Bool?
}

func parseKeySpec(_ spec: String) -> KeySpec? {
    var key = KeySpec()
    var main = spec

    // Detect trailing per-key modifier letters.
    let modSet: Set<Character> = ["b", "d", "f", "h", "M", "n", "r", "V"]
    var modStr = ""
    while let last = main.last, modSet.contains(last) {
        modStr.insert(last, at: modStr.startIndex)
        main.removeLast()
    }
    func applyMods(_ str: String) {
        if str.contains("n") { key.numeric = true }
        if str.contains("r") { key.reverse = true }
        if str.contains("f") { key.ignoreCase = true }
        if str.contains("b") { key.ignoreLeading = true }
        if str.contains("h") { key.humanNumeric = true }
        if str.contains("V") { key.versionSort = true }
        if str.contains("d") { key.dictionaryOrder = true }
        if str.contains("M") { key.monthSort = true }
    }
    applyMods(modStr)

    let parts = main.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard let firstStr = parts.first, !firstStr.isEmpty else { return nil }
    let firstParts = firstStr.split(separator: ".", maxSplits: 1).map(String.init)
    guard let startField = Int(firstParts[0]), startField >= 1 else { return nil }
    key.startField = startField
    if firstParts.count > 1, let startChar = Int(firstParts[1]), startChar >= 1 {
        key.startChar = startChar
    }
    if parts.count > 1 {
        var endPart = parts[1]
        // Trailing modifiers on the end portion too.
        var endMods = ""
        while let last = endPart.last, modSet.contains(last) {
            endMods.insert(last, at: endMods.startIndex)
            endPart.removeLast()
        }
        applyMods(endMods)
        let endParts = endPart.split(separator: ".", maxSplits: 1).map(String.init)
        if let endField = Int(endParts[0]), endField >= 1 {
            key.endField = endField
            if endParts.count > 1, let endChar = Int(endParts[1]), endChar >= 1 {
                key.endChar = endChar
            }
        }
    }
    return key
}

func trimLeadingBlanks(_ str: String) -> String {
    var idx = str.startIndex
    while idx < str.endIndex, str[idx] == " " || str[idx] == "\t" { idx = str.index(after: idx) }
    return String(str[idx...])
}
