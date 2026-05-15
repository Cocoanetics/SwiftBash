import ArgumentParser
import BashInterpreter
import Foundation

/// `join [OPTIONS] FILE1 FILE2` — join lines of two files on a common
/// field. Inputs must be sorted on the join field for paired output to
/// be correct (we don't sort).
///
/// - `-1 N` / `-2 N` — join field for FILE1 / FILE2 (1-based, default 1)
/// - `-t CHAR` — input/output field separator (default: whitespace)
/// - `-a N` — also print unpairable lines from FILE N
/// - `-v N` — print ONLY unpairable lines from FILE N
/// - `-e STR` — replace missing fields with STR (used with -o)
/// - `-o SPEC` — output format `FILENUM.FIELD,FILENUM.FIELD,...`
///   (e.g., `1.1,2.2`)
/// - `-i` / `--ignore-case` — case-insensitive key compare
public struct JoinCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "join",
        abstract: "Join lines of two files on a common field."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then FILE1 FILE2.")
    public var rawArgv: [String] = []

    public init() {}

    private struct Options {
        var field1 = 1
        var field2 = 1
        var separator: Character?
        var printUnpairable = Set<Int>()
        var onlyUnpairable = Set<Int>()
        var emptyString = ""
        var outputFormat: [(file: Int, field: Int)]?
        var ignoreCase = false
    }

    public mutating func execute() async throws -> ExitStatus {
        var opts: Options
        var files: [String]
        switch parseArgs() {
        case .success(let parsed):
            opts = parsed.opts
            files = parsed.files
        case .failure(let code):
            return code
        }

        guard files.count == 2 else {
            Shell.bashCurrent.stderr(
                "join: \(files.count < 2 ? "missing file operand" : "extra operand")\n")
            return ExitStatus(1)
        }

        let texts: [String]
        do {
            texts = try await files.asyncMap { file -> String in
                if file == "-" { return await Shell.bashCurrent.stdin.readAllString() }
                let data = try await Shell.bashCurrent.readDataAtPath(file)
                // Input may have arbitrary bytes; tolerate non-UTF-8.
                // swiftlint:disable:next optional_data_string_conversion
                return String(decoding: data, as: UTF8.self)
            }
        } catch {
            Shell.bashCurrent.stderr("join: \(error)\n")
            return .failure
        }
        let lines1 = SortCommand.splitLines(texts[0])
        let lines2 = SortCommand.splitLines(texts[1])

        let parsed1 = lines1.map { parseLine($0, sep: opts.separator,
                                             field: opts.field1,
                                             ignoreCase: opts.ignoreCase) }
        let parsed2 = lines2.map { parseLine($0, sep: opts.separator,
                                             field: opts.field2,
                                             ignoreCase: opts.ignoreCase) }

        emitJoinedLines(parsed1: parsed1, parsed2: parsed2, opts: opts)
        return .success
    }

    /// Walk the two sorted-by-key line sets, emitting one joined line
    /// per match plus any `-a`/`-v` unpaired lines requested by `opts`.
    private func emitJoinedLines(parsed1: [ParsedLine],
                                 parsed2: [ParsedLine],
                                 opts: Options) {
        // Group rows by key (input must already be sorted, but the
        // index lets us match many-to-many).
        var byKey2: [String: [ParsedLine]] = [:]
        for parsed in parsed2 { byKey2[parsed.joinKey, default: []].append(parsed) }

        var seen2: Set<String> = []
        for parsed in parsed1 {
            if let matches = byKey2[parsed.joinKey] {
                seen2.insert(parsed.joinKey)
                if !opts.onlyUnpairable.isEmpty { continue }
                for match in matches {
                    Shell.bashCurrent.stdout(
                        formatPair(parsed, match, opts: opts) + "\n")
                }
            } else {
                if opts.onlyUnpairable.contains(1) {
                    Shell.bashCurrent.stdout(
                        formatPair(parsed, nil, opts: opts) + "\n")
                } else if opts.printUnpairable.contains(1) {
                    Shell.bashCurrent.stdout(
                        formatPair(parsed, nil, opts: opts) + "\n")
                }
            }
        }
        // Unpaired from file 2.
        if opts.onlyUnpairable.contains(2) || opts.printUnpairable.contains(2) {
            for parsed in parsed2 where !seen2.contains(parsed.joinKey) {
                Shell.bashCurrent.stdout(formatPair(nil, parsed, opts: opts) + "\n")
            }
        }
    }

    private struct ParsedArgs {
        var opts: Options
        var files: [String]
    }

    private enum ArgResult {
        case success(ParsedArgs)
        case failure(ExitStatus)
    }

    // Argv loop: walks -1/-2/-t/-a/-a1/-a2/-v/-v1/-v2/-e/-o/-i. Each
    // option is one short ladder; the whole loop is the dispatch table.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func parseArgs() -> ArgResult {
        var opts = Options()
        var files: [String] = []
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { files.append(rawArgv[index]); index += 1 }
                break
            }
            if arg == "-1" || arg == "-2" {
                guard index + 1 < rawArgv.count,
                      let num = Int(rawArgv[index + 1]), num >= 1 else {
                    Shell.bashCurrent.stderr("join: invalid field number\n")
                    return .failure(ExitStatus(2))
                }
                if arg == "-1" { opts.field1 = num } else { opts.field2 = num }
                index += 2; continue
            }
            if arg == "-t" || arg == "--field-separator" {
                guard index + 1 < rawArgv.count,
                      let char = rawArgv[index + 1].first else {
                    Shell.bashCurrent.stderr("join: -t requires CHAR\n")
                    return .failure(ExitStatus(2))
                }
                opts.separator = char; index += 2; continue
            }
            if arg.hasPrefix("-t") && arg.count > 2 {
                opts.separator = arg[arg.index(arg.startIndex, offsetBy: 2)]
                index += 1; continue
            }
            if arg == "-a" {
                guard index + 1 < rawArgv.count,
                      let num = Int(rawArgv[index + 1]), num == 1 || num == 2 else {
                    Shell.bashCurrent.stderr("join: -a requires 1 or 2\n")
                    return .failure(ExitStatus(2))
                }
                opts.printUnpairable.insert(num); index += 2; continue
            }
            if arg == "-a1" { opts.printUnpairable.insert(1); index += 1; continue }
            if arg == "-a2" { opts.printUnpairable.insert(2); index += 1; continue }
            if arg == "-v" {
                guard index + 1 < rawArgv.count,
                      let num = Int(rawArgv[index + 1]), num == 1 || num == 2 else {
                    Shell.bashCurrent.stderr("join: -v requires 1 or 2\n")
                    return .failure(ExitStatus(2))
                }
                opts.onlyUnpairable.insert(num); index += 2; continue
            }
            if arg == "-v1" { opts.onlyUnpairable.insert(1); index += 1; continue }
            if arg == "-v2" { opts.onlyUnpairable.insert(2); index += 1; continue }
            if arg == "-e" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("join: -e requires STRING\n")
                    return .failure(ExitStatus(2))
                }
                opts.emptyString = rawArgv[index + 1]; index += 2; continue
            }
            if arg == "-o" {
                guard index + 1 < rawArgv.count,
                      let format = parseOutputFormat(rawArgv[index + 1]) else {
                    Shell.bashCurrent.stderr("join: invalid -o format\n")
                    return .failure(ExitStatus(2))
                }
                opts.outputFormat = format; index += 2; continue
            }
            if arg == "-i" || arg == "--ignore-case" {
                opts.ignoreCase = true; index += 1; continue
            }
            if arg.hasPrefix("-") && arg != "-" {
                Shell.bashCurrent.stderr("join: unknown option: \(arg)\n")
                return .failure(ExitStatus(2))
            }
            files.append(arg); index += 1
        }
        return .success(ParsedArgs(opts: opts, files: files))
    }

    // MARK: helpers

    private struct ParsedLine {
        let fields: [String]
        let joinKey: String
        let original: String
    }

    private func parseLine(_ line: String, sep: Character?,
                           field: Int, ignoreCase: Bool) -> ParsedLine {
        let fields: [String]
        if let separator = sep {
            fields = line.split(
                separator: separator,
                omittingEmptySubsequences: false).map(String.init)
        } else {
            fields = line.split(omittingEmptySubsequences: true,
                                whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        var key = field - 1 < fields.count ? fields[field - 1] : ""
        if ignoreCase { key = key.lowercased() }
        return ParsedLine(fields: fields, joinKey: key, original: line)
    }

    private func formatPair(_ line1: ParsedLine?, _ line2: ParsedLine?,
                            opts: Options) -> String {
        let sep = opts.separator.map { String($0) } ?? " "
        if let format = opts.outputFormat {
            var parts: [String] = []
            for entry in format {
                let line = entry.file == 1 ? line1 : line2
                if let line, entry.field == 0 {
                    parts.append(line.joinKey)
                } else if let line, entry.field - 1 < line.fields.count {
                    parts.append(line.fields[entry.field - 1])
                } else {
                    parts.append(opts.emptyString)
                }
            }
            return parts.joined(separator: sep)
        }
        var parts: [String] = []
        let key = line1?.joinKey ?? line2?.joinKey ?? ""
        parts.append(key)
        if let line1 {
            for (index, field) in line1.fields.enumerated()
            where index != opts.field1 - 1 {
                parts.append(field)
            }
        }
        if let line2 {
            for (index, field) in line2.fields.enumerated()
            where index != opts.field2 - 1 {
                parts.append(field)
            }
        }
        return parts.joined(separator: sep)
    }

    private func parseOutputFormat(_ spec: String) -> [(file: Int, field: Int)]? {
        var result: [(Int, Int)] = []
        for part in spec.split(separator: ",") {
            let pieces = part.split(separator: ".")
            guard pieces.count == 2,
                  let file = Int(pieces[0]),
                  let field = Int(pieces[1]),
                  file == 1 || file == 2 else { return nil }
            result.append((file, field))
        }
        return result
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
