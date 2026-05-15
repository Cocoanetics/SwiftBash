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
        if let bad = parseArgs(into: &opts, files: &files) { return bad }
        switch try await readInputs(files: files) {
        case .failure(let exit): return exit
        case .lines(let lines):
            return try await runSort(opts: opts, files: files, lines: lines)
        }
    }

    private enum InputReadResult { case lines([String]), failure(ExitStatus) }

    // MARK: Argument parsing

    private func parseArgs(into opts: inout SortOptions, files: inout [String]) -> ExitStatus? {
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { files.append(rawArgv[index]); index += 1 }
                break
            }
            if arg == "-" {
                files.append("-"); index += 1; continue
            }
            if applySimpleFlag(arg, into: &opts) { index += 1; continue }
            if let status = parseValueFlag(arg, index: &index, opts: &opts) {
                if case .stop(let exit) = status { return exit }
                continue
            }
            if arg.hasPrefix("--") {
                Shell.bashCurrent.stderr("sort: unknown option: \(arg)\n"); return ExitStatus(2)
            }
            if arg.hasPrefix("-") && arg.count > 1 {
                if let exit = applyCombinedShortFlags(arg, into: &opts) { return exit }
                index += 1; continue
            }
            files.append(arg); index += 1
        }
        return nil
    }

    private enum ParseValueResult { case advanced, stop(ExitStatus) }

    nonisolated(unsafe) private static let simpleFlags: [String: WritableKeyPath<SortOptions, Bool>] = [
        "-r": \.reverse, "--reverse": \.reverse,
        "-n": \.numeric, "--numeric-sort": \.numeric,
        "-u": \.unique, "--unique": \.unique,
        "-f": \.ignoreCase, "--ignore-case": \.ignoreCase,
        "-h": \.humanNumeric, "--human-numeric-sort": \.humanNumeric,
        "-V": \.versionSort, "--version-sort": \.versionSort,
        "-d": \.dictionaryOrder, "--dictionary-order": \.dictionaryOrder,
        "-M": \.monthSort, "--month-sort": \.monthSort,
        "-b": \.ignoreLeadingBlanks, "--ignore-leading-blanks": \.ignoreLeadingBlanks,
        "-s": \.stable, "--stable": \.stable,
        "-c": \.checkOnly, "--check": \.checkOnly
    ]

    nonisolated(unsafe) private static let shortFlags: [Character: WritableKeyPath<SortOptions, Bool>] = [
        "r": \.reverse, "n": \.numeric, "u": \.unique, "f": \.ignoreCase,
        "h": \.humanNumeric, "V": \.versionSort, "d": \.dictionaryOrder,
        "M": \.monthSort, "b": \.ignoreLeadingBlanks, "s": \.stable, "c": \.checkOnly
    ]

    private func applySimpleFlag(_ arg: String, into opts: inout SortOptions) -> Bool {
        if let keyPath = Self.simpleFlags[arg] {
            opts[keyPath: keyPath] = true
            return true
        }
        return false
    }

    private func parseValueFlag(_ arg: String, index: inout Int,
                                opts: inout SortOptions) -> ParseValueResult? {
        if let result = parseOutput(arg, index: &index, opts: &opts) { return result }
        if let result = parseFieldSeparator(arg, index: &index, opts: &opts) { return result }
        if let result = parseKey(arg, index: &index, opts: &opts) { return result }
        return nil
    }

    private func parseOutput(_ arg: String, index: inout Int,
                             opts: inout SortOptions) -> ParseValueResult? {
        if arg == "-o" || arg == "--output" {
            guard index + 1 < rawArgv.count else {
                Shell.bashCurrent.stderr("sort: -o requires FILE\n")
                return .stop(ExitStatus(2))
            }
            opts.outputFile = rawArgv[index + 1]; index += 2; return .advanced
        }
        if arg.hasPrefix("-o") && arg.count > 2 {
            opts.outputFile = String(arg.dropFirst(2)); index += 1; return .advanced
        }
        if arg.hasPrefix("--output=") {
            opts.outputFile = String(arg.dropFirst("--output=".count)); index += 1; return .advanced
        }
        return nil
    }

    private func parseFieldSeparator(_ arg: String, index: inout Int,
                                     opts: inout SortOptions) -> ParseValueResult? {
        if arg == "-t" || arg == "--field-separator" {
            guard index + 1 < rawArgv.count else {
                Shell.bashCurrent.stderr("sort: -t requires SEP\n")
                return .stop(ExitStatus(2))
            }
            opts.fieldDelimiter = rawArgv[index + 1]; index += 2; return .advanced
        }
        if arg.hasPrefix("-t") && arg.count > 2 {
            opts.fieldDelimiter = String(arg.dropFirst(2)); index += 1; return .advanced
        }
        if arg.hasPrefix("--field-separator=") {
            opts.fieldDelimiter = String(arg.dropFirst("--field-separator=".count))
            index += 1; return .advanced
        }
        return nil
    }

    private func parseKey(_ arg: String, index: inout Int,
                          opts: inout SortOptions) -> ParseValueResult? {
        if arg == "-k" || arg == "--key" {
            guard index + 1 < rawArgv.count else {
                Shell.bashCurrent.stderr("sort: -k requires KEYDEF\n")
                return .stop(ExitStatus(2))
            }
            if let key = parseKeySpec(rawArgv[index + 1]) { opts.keys.append(key) }
            index += 2; return .advanced
        }
        if arg.hasPrefix("-k") && arg.count > 2 {
            if let key = parseKeySpec(String(arg.dropFirst(2))) { opts.keys.append(key) }
            index += 1; return .advanced
        }
        if arg.hasPrefix("--key=") {
            if let key = parseKeySpec(String(arg.dropFirst("--key=".count))) {
                opts.keys.append(key)
            }
            index += 1; return .advanced
        }
        return nil
    }

    private func applyCombinedShortFlags(_ arg: String, into opts: inout SortOptions) -> ExitStatus? {
        // Combined short flags like -rn, -bf, etc.
        for char in arg.dropFirst() {
            guard let keyPath = Self.shortFlags[char] else {
                Shell.bashCurrent.stderr("sort: unknown option: -\(char)\n")
                return ExitStatus(2)
            }
            opts[keyPath: keyPath] = true
        }
        return nil
    }

    private func readInputs(files: [String]) async throws -> InputReadResult {
        var lines: [String] = []
        if files.isEmpty {
            for await line in Shell.bashCurrent.stdin.lines { lines.append(line) }
        } else {
            for file in files {
                try Task.checkCancellation()
                do {
                    let data = try await Shell.bashCurrent.readDataAtPath(file)
                    // swiftlint:disable:next optional_data_string_conversion - sort input may be partial UTF-8
                    let text = String(decoding: data, as: UTF8.self)
                    lines.append(contentsOf: SortCommand.splitLines(text))
                } catch {
                    Shell.bashCurrent.stderr("sort: \(file): \(error)\n")
                    return .failure(.failure)
                }
            }
        }
        return .lines(lines)
    }

    private func runSort(opts: SortOptions, files: [String],
                         lines linesIn: [String]) async throws -> ExitStatus {
        var lines = linesIn
        let cmp = makeComparator(opts)
        if opts.checkOnly {
            let label = files.first ?? "-"
            for lineIndex in 1..<lines.count where cmp(lines[lineIndex - 1], lines[lineIndex]) > 0 {
                Shell.bashCurrent.stderr("sort: \(label):\(lineIndex + 1): disorder: \(lines[lineIndex])\n")
                return ExitStatus(1)
            }
            return .success
        }
        // Stable sort needed when --stable; Swift's `sort(by:)` isn't
        // stable, so we use a sort-by-index trick.
        if opts.stable {
            var indexed = lines.enumerated().map { ($0.offset, $0.element) }
            indexed.sort { lhs, rhs in
                let cmpResult = cmp(lhs.1, rhs.1)
                return cmpResult == 0 ? lhs.0 < rhs.0 : cmpResult < 0
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
                try await Shell.bashCurrent.writeData(Data(output.utf8), toPath: outPath, append: false)
            } catch {
                Shell.bashCurrent.stderr("sort: \(outPath): \(error)\n")
                return .failure
            }
        } else {
            Shell.bashCurrent.stdout(output)
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

    // Numeric prefix helpers, comparator, comparison helpers, dedupe,
    // and extractKey live in `SortCommand+Compare.swift`. Supporting
    // types live in `SortCommand+Types.swift`.
}
