import Foundation

// MARK: - Comparator and comparison helpers

extension SortCommand {
    func makeComparator(_ opts: SortOptions) -> (String, String) -> Int {
        let keys = opts.keys
        let delim = opts.fieldDelimiter
        return { lhs, rhs in
            var lhsLine = lhs, rhsLine = rhs
            if opts.ignoreLeadingBlanks {
                lhsLine = trimLeadingBlanks(lhsLine); rhsLine = trimLeadingBlanks(rhsLine)
            }
            if keys.isEmpty {
                let cmpOpts = CompareOptions(
                    numeric: opts.numeric,
                    ignoreCase: opts.ignoreCase,
                    humanNumeric: opts.humanNumeric,
                    versionSort: opts.versionSort,
                    dictionaryOrder: opts.dictionaryOrder,
                    monthSort: opts.monthSort)
                let result = compareValues(lhsLine, rhsLine, options: cmpOpts)
                if result != 0 { return opts.reverse ? -result : result }
                if opts.stable { return 0 }
                let tie = lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
                return opts.reverse ? -tie : tie
            }
            for key in keys {
                var lhsVal = extractKey(lhsLine, key: key, delim: delim)
                var rhsVal = extractKey(rhsLine, key: key, delim: delim)
                if key.ignoreLeading == true {
                    lhsVal = trimLeadingBlanks(lhsVal); rhsVal = trimLeadingBlanks(rhsVal)
                }
                let cmpOpts = CompareOptions(
                    numeric: key.numeric ?? opts.numeric,
                    ignoreCase: key.ignoreCase ?? opts.ignoreCase,
                    humanNumeric: key.humanNumeric ?? opts.humanNumeric,
                    versionSort: key.versionSort ?? opts.versionSort,
                    dictionaryOrder: key.dictionaryOrder ?? opts.dictionaryOrder,
                    monthSort: key.monthSort ?? opts.monthSort)
                let result = compareValues(lhsVal, rhsVal, options: cmpOpts)
                let useReverse = key.reverse ?? opts.reverse
                if result != 0 { return useReverse ? -result : result }
            }
            if opts.stable { return 0 }
            let tie = lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
            return opts.reverse ? -tie : tie
        }
    }

    static func dedupe(_ lines: [String], opts: SortOptions) -> [String] {
        if opts.keys.isEmpty {
            // Whole-line uniqueness honouring case folding.
            var seen = Set<String>()
            return lines.filter {
                let key = opts.ignoreCase ? $0.lowercased() : $0
                if seen.contains(key) { return false }
                seen.insert(key); return true
            }
        }
        let key = opts.keys[0]
        var seen = Set<String>()
        return lines.filter {
            var keyVal = extractKey($0, key: key, delim: opts.fieldDelimiter)
            if key.ignoreCase ?? opts.ignoreCase { keyVal = keyVal.lowercased() }
            if seen.contains(keyVal) { return false }
            seen.insert(keyVal); return true
        }
    }
}

// MARK: - File-private comparison primitives

/// Options describing how `compareValues` should order a pair of strings.
struct CompareOptions {
    var numeric: Bool
    var ignoreCase: Bool
    var humanNumeric: Bool
    var versionSort: Bool
    var dictionaryOrder: Bool
    var monthSort: Bool
}

func compareValues(_ lhs: String, _ rhs: String, options: CompareOptions) -> Int {
    var lhsVal = lhs, rhsVal = rhs
    if options.dictionaryOrder { lhsVal = toDict(lhsVal); rhsVal = toDict(rhsVal) }
    if options.ignoreCase { lhsVal = lhsVal.lowercased(); rhsVal = rhsVal.lowercased() }
    if options.monthSort { return parseMonth(lhsVal) - parseMonth(rhsVal) }
    if options.humanNumeric {
        let lhsNum = parseHumanSize(lhsVal), rhsNum = parseHumanSize(rhsVal)
        return lhsNum < rhsNum ? -1 : (lhsNum > rhsNum ? 1 : 0)
    }
    if options.versionSort {
        return compareVersions(lhsVal, rhsVal)
    }
    if options.numeric {
        let lhsNum = numericPrefix(lhsVal), rhsNum = numericPrefix(rhsVal)
        return lhsNum < rhsNum ? -1 : (lhsNum > rhsNum ? 1 : 0)
    }
    return lhsVal == rhsVal ? 0 : (lhsVal < rhsVal ? -1 : 1)
}

func toDict(_ str: String) -> String {
    str.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
}

private let humanSizeMultipliers: [String: Double] = [
    "k": 1024, "m": 1024 * 1024, "g": 1024 * 1024 * 1024,
    "t": pow(1024, 4), "p": pow(1024, 5), "e": pow(1024, 6)
]

func parseHumanSize(_ str: String) -> Double {
    let trimmed = str.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return 0 }
    var endIdx = trimmed.startIndex
    if trimmed[endIdx] == "+" || trimmed[endIdx] == "-" {
        endIdx = trimmed.index(after: endIdx)
    }
    while endIdx < trimmed.endIndex, trimmed[endIdx].isNumber || trimmed[endIdx] == "." {
        endIdx = trimmed.index(after: endIdx)
    }
    let num = Double(trimmed[trimmed.startIndex..<endIdx]) ?? 0
    var mult = 1.0
    if endIdx < trimmed.endIndex {
        mult = humanSizeMultipliers[trimmed[endIdx].lowercased()] ?? 1.0
    }
    return num * mult
}

func parseMonth(_ str: String) -> Int {
    let trimmed = str.trimmingCharacters(in: .whitespaces).lowercased()
    guard trimmed.count >= 3 else { return 0 }
    let prefix = String(trimmed.prefix(3))
    let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                  "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    return months[prefix] ?? 0
}

/// Natural version compare — splits into numeric / non-numeric runs
/// and compares run-by-run.
func compareVersions(_ lhs: String, _ rhs: String) -> Int {
    let lhsParts = splitVersionParts(lhs)
    let rhsParts = splitVersionParts(rhs)
    for idx in 0..<max(lhsParts.count, rhsParts.count) {
        let lhsPart = idx < lhsParts.count ? lhsParts[idx] : ""
        let rhsPart = idx < rhsParts.count ? rhsParts[idx] : ""
        let lhsNum = Int(lhsPart), rhsNum = Int(rhsPart)
        if let lhsNum, let rhsNum {
            if lhsNum != rhsNum { return lhsNum < rhsNum ? -1 : 1 }
        } else {
            if lhsPart != rhsPart { return lhsPart < rhsPart ? -1 : 1 }
        }
    }
    return 0
}

func splitVersionParts(_ str: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inDigits = false
    for char in str {
        let isDigit = char.isASCII && char.isNumber
        if !current.isEmpty && isDigit != inDigits {
            parts.append(current); current = ""
        }
        current.append(char); inDigits = isDigit
    }
    if !current.isEmpty { parts.append(current) }
    return parts
}

func extractKey(_ line: String, key: KeySpec, delim: String?) -> String {
    let fields: [String]
    if let delim {
        fields = line.components(separatedBy: delim)
    } else {
        fields = line.split(omittingEmptySubsequences: true,
                            whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
    let startIdx = key.startField - 1
    if startIdx >= fields.count { return "" }
    if key.endField == nil {
        var field = fields[startIdx]
        if let startChar = key.startChar { field = String(field.dropFirst(startChar - 1)) }
        return field
    }
    let endIdx = min((key.endField ?? fields.count) - 1, fields.count - 1)
    var pieces: [String] = []
    for idx in startIdx...endIdx {
        var field = fields[idx]
        if idx == startIdx, let startChar = key.startChar {
            field = String(field.dropFirst(startChar - 1))
        }
        if idx == endIdx, let endChar = key.endChar {
            let limit: Int
            if idx == startIdx, let startChar = key.startChar {
                limit = max(0, endChar - startChar + 1)
            } else {
                limit = endChar
            }
            field = String(field.prefix(limit))
        }
        pieces.append(field)
    }
    return pieces.joined(separator: delim ?? " ")
}

// MARK: - Public-API helpers preserved for callers outside the file

extension SortCommand {
    static func numericLess(_ lhs: String, _ rhs: String) -> Bool {
        numericPrefix(lhs) < numericPrefix(rhs)
    }

    static func numericPrefix(_ str: String) -> Double {
        var idx = str.startIndex
        while idx < str.endIndex, str[idx] == " " || str[idx] == "\t" { idx = str.index(after: idx) }
        let signStart = idx
        if idx < str.endIndex, str[idx] == "-" || str[idx] == "+" { idx = str.index(after: idx) }
        while idx < str.endIndex, str[idx].isNumber || str[idx] == "." { idx = str.index(after: idx) }
        return Double(str[signStart..<idx]) ?? 0
    }

    static func collapseAdjacent(_ lines: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines where out.last != line { out.append(line) }
        return out
    }
}

func numericPrefix(_ str: String) -> Double {
    SortCommand.numericPrefix(str)
}
