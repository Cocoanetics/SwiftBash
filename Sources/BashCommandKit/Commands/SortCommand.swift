import ArgumentParser
import BashInterpreter
import Foundation

/// `sort [OPTION]... [FILE]...` — sort lines.
///
/// Supports the GNU sort flag set:
/// - `-r` / `--reverse` — reverse the comparison
/// - `-n` / `--numeric-sort` — numeric prefix
/// - `-h` / `--human-numeric-sort` — sizes like `1K 2.5M 3G`
/// - `-V` / `--version-sort` — natural sort of version-style strings
/// - `-d` / `--dictionary-order` — alphanumeric and blanks only
/// - `-M` / `--month-sort` — JAN < FEB … < DEC
/// - `-f` / `--ignore-case` — fold case
/// - `-b` / `--ignore-leading-blanks` — trim leading whitespace
/// - `-u` / `--unique` — drop duplicates
/// - `-s` / `--stable` — disable last-resort line tiebreaker
/// - `-c` / `--check` — verify input is sorted; exit 1 otherwise
/// - `-o FILE` / `--output=FILE` — write to file instead of stdout
/// - `-t SEP` / `--field-separator=SEP` — custom field delimiter
/// - `-k KEYDEF` / `--key=KEYDEF` — sort by `F[.C][OPTS][,F[.C][OPTS]]`,
///   repeatable. Per-key OPTS override globals.
public struct SortCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sort",
        abstract: "Sort lines."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var opts = SortOptions()
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-" {
                files.append("-"); i += 1; continue
            }
            switch a {
            case "-r", "--reverse": opts.reverse = true; i += 1; continue
            case "-n", "--numeric-sort": opts.numeric = true; i += 1; continue
            case "-u", "--unique": opts.unique = true; i += 1; continue
            case "-f", "--ignore-case": opts.ignoreCase = true; i += 1; continue
            case "-h", "--human-numeric-sort": opts.humanNumeric = true; i += 1; continue
            case "-V", "--version-sort": opts.versionSort = true; i += 1; continue
            case "-d", "--dictionary-order": opts.dictionaryOrder = true; i += 1; continue
            case "-M", "--month-sort": opts.monthSort = true; i += 1; continue
            case "-b", "--ignore-leading-blanks": opts.ignoreLeadingBlanks = true; i += 1; continue
            case "-s", "--stable": opts.stable = true; i += 1; continue
            case "-c", "--check": opts.checkOnly = true; i += 1; continue
            default: break
            }
            if a == "-o" || a == "--output" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("sort: -o requires FILE\n"); return ExitStatus(2)
                }
                opts.outputFile = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("-o") && a.count > 2 {
                opts.outputFile = String(a.dropFirst(2)); i += 1; continue
            }
            if a.hasPrefix("--output=") {
                opts.outputFile = String(a.dropFirst("--output=".count)); i += 1; continue
            }
            if a == "-t" || a == "--field-separator" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("sort: -t requires SEP\n"); return ExitStatus(2)
                }
                opts.fieldDelimiter = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("-t") && a.count > 2 {
                opts.fieldDelimiter = String(a.dropFirst(2)); i += 1; continue
            }
            if a.hasPrefix("--field-separator=") {
                opts.fieldDelimiter = String(a.dropFirst("--field-separator=".count))
                i += 1; continue
            }
            if a == "-k" || a == "--key" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("sort: -k requires KEYDEF\n"); return ExitStatus(2)
                }
                if let k = parseKeySpec(rawArgv[i + 1]) { opts.keys.append(k) }
                i += 2; continue
            }
            if a.hasPrefix("-k") && a.count > 2 {
                if let k = parseKeySpec(String(a.dropFirst(2))) { opts.keys.append(k) }
                i += 1; continue
            }
            if a.hasPrefix("--key=") {
                if let k = parseKeySpec(String(a.dropFirst("--key=".count))) {
                    opts.keys.append(k)
                }
                i += 1; continue
            }
            if a.hasPrefix("--") {
                Shell.current.stderr("sort: unknown option: \(a)\n"); return ExitStatus(2)
            }
            if a.hasPrefix("-") && a.count > 1 {
                // Combined short flags like -rn, -bf, etc.
                for c in a.dropFirst() {
                    switch c {
                    case "r": opts.reverse = true
                    case "n": opts.numeric = true
                    case "u": opts.unique = true
                    case "f": opts.ignoreCase = true
                    case "h": opts.humanNumeric = true
                    case "V": opts.versionSort = true
                    case "d": opts.dictionaryOrder = true
                    case "M": opts.monthSort = true
                    case "b": opts.ignoreLeadingBlanks = true
                    case "s": opts.stable = true
                    case "c": opts.checkOnly = true
                    default:
                        Shell.current.stderr("sort: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            files.append(a); i += 1
        }

        // Read inputs.
        var lines: [String] = []
        if files.isEmpty {
            for await line in Shell.current.stdin.lines { lines.append(line) }
        } else {
            for f in files {
                do {
                    let data = try await Shell.current.readDataAtPath(f)
                    let text = String(decoding: data, as: UTF8.self)
                    lines.append(contentsOf: SortCommand.splitLines(text))
                } catch {
                    Shell.current.stderr("sort: \(f): \(error)\n")
                    return .failure
                }
            }
        }

        // Build comparator.
        let cmp = makeComparator(opts)

        if opts.checkOnly {
            let label = files.first ?? "-"
            for j in 1..<lines.count {
                if cmp(lines[j - 1], lines[j]) > 0 {
                    Shell.current.stderr("sort: \(label):\(j + 1): disorder: \(lines[j])\n")
                    return ExitStatus(1)
                }
            }
            return .success
        }

        // Stable sort needed when --stable; Swift's `sort(by:)` isn't
        // stable, so we use a sort-by-index trick.
        if opts.stable {
            var indexed = lines.enumerated().map { ($0.offset, $0.element) }
            indexed.sort { lhs, rhs in
                let c = cmp(lhs.1, rhs.1)
                return c == 0 ? lhs.0 < rhs.0 : c < 0
            }
            lines = indexed.map { $0.1 }
        } else {
            lines.sort { cmp($0, $1) < 0 }
        }

        if opts.unique {
            lines = Self.dedupe(lines, opts: opts)
        }

        let output = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        if let outPath = opts.outputFile {
            do {
                try await Shell.current.writeData(Data(output.utf8), toPath: outPath, append: false)
            } catch {
                Shell.current.stderr("sort: \(outPath): \(error)\n")
                return .failure
            }
        } else {
            Shell.current.stdout(output)
        }
        return .success
    }

    // MARK: Public helpers (called by other commands)

    /// Split text into lines without producing a phantom empty line for
    /// a trailing newline. `"a\nb\n"` → `["a", "b"]`.
    public static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    // MARK: Numeric prefix helpers (kept for backward compat)

    static func numericLess(_ a: String, _ b: String) -> Bool {
        numericPrefix(a) < numericPrefix(b)
    }
    static func numericPrefix(_ s: String) -> Double {
        var i = s.startIndex
        while i < s.endIndex, s[i] == " " || s[i] == "\t" { i = s.index(after: i) }
        let signStart = i
        if i < s.endIndex, s[i] == "-" || s[i] == "+" { i = s.index(after: i) }
        while i < s.endIndex, s[i].isNumber || s[i] == "." { i = s.index(after: i) }
        return Double(s[signStart..<i]) ?? 0
    }
    static func collapseAdjacent(_ lines: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for l in lines { if out.last != l { out.append(l) } }
        return out
    }

    // MARK: Comparator

    private func makeComparator(_ opts: SortOptions) -> (String, String) -> Int {
        let keys = opts.keys
        let delim = opts.fieldDelimiter
        return { a, b in
            var la = a, lb = b
            if opts.ignoreLeadingBlanks {
                la = trimLeadingBlanks(la); lb = trimLeadingBlanks(lb)
            }
            if keys.isEmpty {
                let r = SortCommand.compareValues(la, lb,
                                                  numeric: opts.numeric,
                                                  ignoreCase: opts.ignoreCase,
                                                  humanNumeric: opts.humanNumeric,
                                                  versionSort: opts.versionSort,
                                                  dictionaryOrder: opts.dictionaryOrder,
                                                  monthSort: opts.monthSort)
                if r != 0 { return opts.reverse ? -r : r }
                if opts.stable { return 0 }
                let tie = a == b ? 0 : (a < b ? -1 : 1)
                return opts.reverse ? -tie : tie
            }
            for k in keys {
                var va = SortCommand.extractKey(la, key: k, delim: delim)
                var vb = SortCommand.extractKey(lb, key: k, delim: delim)
                if k.ignoreLeading == true {
                    va = trimLeadingBlanks(va); vb = trimLeadingBlanks(vb)
                }
                let r = SortCommand.compareValues(va, vb,
                                                  numeric: k.numeric ?? opts.numeric,
                                                  ignoreCase: k.ignoreCase ?? opts.ignoreCase,
                                                  humanNumeric: k.humanNumeric ?? opts.humanNumeric,
                                                  versionSort: k.versionSort ?? opts.versionSort,
                                                  dictionaryOrder: k.dictionaryOrder ?? opts.dictionaryOrder,
                                                  monthSort: k.monthSort ?? opts.monthSort)
                let useReverse = k.reverse ?? opts.reverse
                if r != 0 { return useReverse ? -r : r }
            }
            if opts.stable { return 0 }
            let tie = a == b ? 0 : (a < b ? -1 : 1)
            return opts.reverse ? -tie : tie
        }
    }

    // MARK: Comparison helpers

    static func compareValues(_ a: String, _ b: String,
                              numeric: Bool, ignoreCase: Bool,
                              humanNumeric: Bool, versionSort: Bool,
                              dictionaryOrder: Bool, monthSort: Bool) -> Int {
        var va = a, vb = b
        if dictionaryOrder { va = toDict(va); vb = toDict(vb) }
        if ignoreCase { va = va.lowercased(); vb = vb.lowercased() }
        if monthSort { return parseMonth(va) - parseMonth(vb) }
        if humanNumeric {
            let na = parseHumanSize(va), nb = parseHumanSize(vb)
            return na < nb ? -1 : (na > nb ? 1 : 0)
        }
        if versionSort {
            return compareVersions(va, vb)
        }
        if numeric {
            let na = numericPrefix(va), nb = numericPrefix(vb)
            return na < nb ? -1 : (na > nb ? 1 : 0)
        }
        return va == vb ? 0 : (va < vb ? -1 : 1)
    }

    static func toDict(_ s: String) -> String {
        s.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }

    static func parseHumanSize(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return 0 }
        var endIdx = t.startIndex
        if t[endIdx] == "+" || t[endIdx] == "-" { endIdx = t.index(after: endIdx) }
        while endIdx < t.endIndex, t[endIdx].isNumber || t[endIdx] == "." {
            endIdx = t.index(after: endIdx)
        }
        let num = Double(t[t.startIndex..<endIdx]) ?? 0
        var mult = 1.0
        if endIdx < t.endIndex {
            switch t[endIdx].lowercased() {
            case "k": mult = 1024
            case "m": mult = 1024 * 1024
            case "g": mult = 1024 * 1024 * 1024
            case "t": mult = pow(1024, 4)
            case "p": mult = pow(1024, 5)
            case "e": mult = pow(1024, 6)
            default: break
            }
        }
        return num * mult
    }

    static func parseMonth(_ s: String) -> Int {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.count >= 3 else { return 0 }
        let prefix = String(t.prefix(3))
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        return months[prefix] ?? 0
    }

    /// Natural version compare — splits into numeric / non-numeric runs
    /// and compares run-by-run.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = splitVersionParts(a)
        let pb = splitVersionParts(b)
        for i in 0..<max(pa.count, pb.count) {
            let xa = i < pa.count ? pa[i] : ""
            let xb = i < pb.count ? pb[i] : ""
            let na = Int(xa), nb = Int(xb)
            if let na, let nb {
                if na != nb { return na < nb ? -1 : 1 }
            } else {
                if xa != xb { return xa < xb ? -1 : 1 }
            }
        }
        return 0
    }
    static func splitVersionParts(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inDigits = false
        for c in s {
            let d = c.isASCII && c.isNumber
            if !current.isEmpty && d != inDigits {
                parts.append(current); current = ""
            }
            current.append(c); inDigits = d
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func extractKey(_ line: String, key: KeySpec, delim: String?) -> String {
        let fields: [String]
        if let d = delim {
            fields = line.components(separatedBy: d)
        } else {
            fields = line.split(omittingEmptySubsequences: true,
                                whereSeparator: { $0.isWhitespace })
                .map(String.init)
        }
        let startIdx = key.startField - 1
        if startIdx >= fields.count { return "" }
        if key.endField == nil {
            var f = fields[startIdx]
            if let c = key.startChar { f = String(f.dropFirst(c - 1)) }
            return f
        }
        let endIdx = min((key.endField ?? fields.count) - 1, fields.count - 1)
        var pieces: [String] = []
        for i in startIdx...endIdx {
            var f = fields[i]
            if i == startIdx, let c = key.startChar {
                f = String(f.dropFirst(c - 1))
            }
            if i == endIdx, let c = key.endChar {
                let limit: Int
                if i == startIdx, let s = key.startChar {
                    limit = max(0, c - s + 1)
                } else {
                    limit = c
                }
                f = String(f.prefix(limit))
            }
            pieces.append(f)
        }
        return pieces.joined(separator: delim ?? " ")
    }

    static func dedupe(_ lines: [String], opts: SortOptions) -> [String] {
        if opts.keys.isEmpty {
            // Whole-line uniqueness honouring case folding.
            var seen = Set<String>()
            return lines.filter {
                let k = opts.ignoreCase ? $0.lowercased() : $0
                if seen.contains(k) { return false }
                seen.insert(k); return true
            }
        }
        let key = opts.keys[0]
        var seen = Set<String>()
        return lines.filter {
            var k = extractKey($0, key: key, delim: opts.fieldDelimiter)
            if (key.ignoreCase ?? opts.ignoreCase) { k = k.lowercased() }
            if seen.contains(k) { return false }
            seen.insert(k); return true
        }
    }
}

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
    var outputFile: String? = nil
    var keys: [KeySpec] = []
    var fieldDelimiter: String? = nil
}

struct KeySpec {
    var startField: Int = 1
    var startChar: Int? = nil
    var endField: Int? = nil
    var endChar: Int? = nil
    var numeric: Bool? = nil
    var reverse: Bool? = nil
    var ignoreCase: Bool? = nil
    var ignoreLeading: Bool? = nil
    var humanNumeric: Bool? = nil
    var versionSort: Bool? = nil
    var dictionaryOrder: Bool? = nil
    var monthSort: Bool? = nil
}

func parseKeySpec(_ spec: String) -> KeySpec? {
    var k = KeySpec()
    var main = spec

    // Detect trailing per-key modifier letters.
    let modSet: Set<Character> = ["b", "d", "f", "h", "M", "n", "r", "V"]
    var modStr = ""
    while let last = main.last, modSet.contains(last) {
        modStr.insert(last, at: modStr.startIndex)
        main.removeLast()
    }
    func applyMods(_ s: String) {
        if s.contains("n") { k.numeric = true }
        if s.contains("r") { k.reverse = true }
        if s.contains("f") { k.ignoreCase = true }
        if s.contains("b") { k.ignoreLeading = true }
        if s.contains("h") { k.humanNumeric = true }
        if s.contains("V") { k.versionSort = true }
        if s.contains("d") { k.dictionaryOrder = true }
        if s.contains("M") { k.monthSort = true }
    }
    applyMods(modStr)

    let parts = main.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard let firstStr = parts.first, !firstStr.isEmpty else { return nil }
    let firstParts = firstStr.split(separator: ".", maxSplits: 1).map(String.init)
    guard let f1 = Int(firstParts[0]), f1 >= 1 else { return nil }
    k.startField = f1
    if firstParts.count > 1, let c = Int(firstParts[1]), c >= 1 {
        k.startChar = c
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
        if let f2 = Int(endParts[0]), f2 >= 1 {
            k.endField = f2
            if endParts.count > 1, let c = Int(endParts[1]), c >= 1 {
                k.endChar = c
            }
        }
    }
    return k
}

private func trimLeadingBlanks(_ s: String) -> String {
    var i = s.startIndex
    while i < s.endIndex, s[i] == " " || s[i] == "\t" { i = s.index(after: i) }
    return String(s[i...])
}
