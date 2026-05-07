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
        var separator: Character? = nil
        var printUnpairable = Set<Int>()
        var onlyUnpairable = Set<Int>()
        var emptyString = ""
        var outputFormat: [(file: Int, field: Int)]? = nil
        var ignoreCase = false
    }

    public mutating func execute() async throws -> ExitStatus {
        var opts = Options()
        var files: [String] = []
        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-1" || a == "-2" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n >= 1 else {
                    Shell.bashCurrent.stderr("join: invalid field number\n"); return ExitStatus(2)
                }
                if a == "-1" { opts.field1 = n } else { opts.field2 = n }
                i += 2; continue
            }
            if a == "-t" || a == "--field-separator" {
                guard i + 1 < rawArgv.count, let c = rawArgv[i + 1].first else {
                    Shell.bashCurrent.stderr("join: -t requires CHAR\n"); return ExitStatus(2)
                }
                opts.separator = c; i += 2; continue
            }
            if a.hasPrefix("-t") && a.count > 2 {
                opts.separator = a[a.index(a.startIndex, offsetBy: 2)]
                i += 1; continue
            }
            if a == "-a" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n == 1 || n == 2 else {
                    Shell.bashCurrent.stderr("join: -a requires 1 or 2\n"); return ExitStatus(2)
                }
                opts.printUnpairable.insert(n); i += 2; continue
            }
            if a == "-a1" { opts.printUnpairable.insert(1); i += 1; continue }
            if a == "-a2" { opts.printUnpairable.insert(2); i += 1; continue }
            if a == "-v" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n == 1 || n == 2 else {
                    Shell.bashCurrent.stderr("join: -v requires 1 or 2\n"); return ExitStatus(2)
                }
                opts.onlyUnpairable.insert(n); i += 2; continue
            }
            if a == "-v1" { opts.onlyUnpairable.insert(1); i += 1; continue }
            if a == "-v2" { opts.onlyUnpairable.insert(2); i += 1; continue }
            if a == "-e" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("join: -e requires STRING\n"); return ExitStatus(2)
                }
                opts.emptyString = rawArgv[i + 1]; i += 2; continue
            }
            if a == "-o" {
                guard i + 1 < rawArgv.count, let f = parseOutputFormat(rawArgv[i + 1]) else {
                    Shell.bashCurrent.stderr("join: invalid -o format\n"); return ExitStatus(2)
                }
                opts.outputFormat = f; i += 2; continue
            }
            if a == "-i" || a == "--ignore-case" {
                opts.ignoreCase = true; i += 1; continue
            }
            if a.hasPrefix("-") && a != "-" {
                Shell.bashCurrent.stderr("join: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        guard files.count == 2 else {
            Shell.bashCurrent.stderr("join: \(files.count < 2 ? "missing file operand" : "extra operand")\n")
            return ExitStatus(1)
        }

        let texts: [String]
        do {
            texts = try await files.asyncMap { f -> String in
                if f == "-" { return await Shell.bashCurrent.stdin.readAllString() }
                let data = try await Shell.bashCurrent.readDataAtPath(f)
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

        // Group rows by key (input must already be sorted, but the
        // index lets us match many-to-many).
        var byKey2: [String: [ParsedLine]] = [:]
        for p in parsed2 { byKey2[p.joinKey, default: []].append(p) }

        var seen2: Set<String> = []
        for p1 in parsed1 {
            if let matches = byKey2[p1.joinKey] {
                seen2.insert(p1.joinKey)
                if !opts.onlyUnpairable.isEmpty { continue }
                for p2 in matches {
                    Shell.bashCurrent.stdout(formatPair(p1, p2, opts: opts) + "\n")
                }
            } else {
                if opts.onlyUnpairable.contains(1) {
                    Shell.bashCurrent.stdout(formatPair(p1, nil, opts: opts) + "\n")
                } else if opts.printUnpairable.contains(1) {
                    Shell.bashCurrent.stdout(formatPair(p1, nil, opts: opts) + "\n")
                }
            }
        }
        // Unpaired from file 2.
        if opts.onlyUnpairable.contains(2) || opts.printUnpairable.contains(2) {
            for p2 in parsed2 where !seen2.contains(p2.joinKey) {
                Shell.bashCurrent.stdout(formatPair(nil, p2, opts: opts) + "\n")
            }
        }
        return .success
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
        if let s = sep {
            fields = line.split(separator: s, omittingEmptySubsequences: false).map(String.init)
        } else {
            fields = line.split(omittingEmptySubsequences: true,
                                whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        var key = field - 1 < fields.count ? fields[field - 1] : ""
        if ignoreCase { key = key.lowercased() }
        return ParsedLine(fields: fields, joinKey: key, original: line)
    }

    private func formatPair(_ l1: ParsedLine?, _ l2: ParsedLine?,
                            opts: Options) -> String {
        let sep = opts.separator.map { String($0) } ?? " "
        if let format = opts.outputFormat {
            var parts: [String] = []
            for entry in format {
                let line = entry.file == 1 ? l1 : l2
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
        let key = l1?.joinKey ?? l2?.joinKey ?? ""
        parts.append(key)
        if let l1 {
            for (i, f) in l1.fields.enumerated() where i != opts.field1 - 1 {
                parts.append(f)
            }
        }
        if let l2 {
            for (i, f) in l2.fields.enumerated() where i != opts.field2 - 1 {
                parts.append(f)
            }
        }
        return parts.joined(separator: sep)
    }

    private func parseOutputFormat(_ s: String) -> [(file: Int, field: Int)]? {
        var result: [(Int, Int)] = []
        for part in s.split(separator: ",") {
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
        for e in self { out.append(try await transform(e)) }
        return out
    }
}
