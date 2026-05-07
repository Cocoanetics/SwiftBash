import ArgumentParser
import BashInterpreter
import Foundation

/// `cut [OPTIONS] [FILE...]` — extract slices from each input line.
///
/// One of `-f` (fields), `-c` (characters), or `-b` (bytes) selects
/// the mode. All three accept a comma-separated list of 1-based
/// numbers and inclusive ranges (`1`, `1,3`, `2-4`, `3-`, `-3`,
/// `1,3-5,8`).
///
/// Field mode (`-f`):
/// - `-d DELIM` — single-byte delimiter (default tab)
/// - `--output-delimiter=STR` — separator for emitted fields (default
///   matches the input delimiter)
/// - `-s` / `--only-delimited` — drop lines without the delimiter
///
/// Cross-cutting:
/// - `--complement` — emit the slices NOT selected
public struct CutCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cut",
        abstract: "Extract slices from each line."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    enum Mode { case fields, chars, bytes }

    public mutating func execute() async throws -> ExitStatus {
        var listStr: String? = nil
        var mode: Mode = .fields
        var delim: String = "\t"
        var outputDelim: String? = nil
        var onlyDelimited = false
        var complement = false
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-" { files.append("-"); i += 1; continue }
            if a == "-f" || a == "--fields" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("cut: -f requires LIST\n"); return ExitStatus(2)
                }
                listStr = rawArgv[i + 1]; mode = .fields; i += 2; continue
            }
            if a.hasPrefix("--fields=") {
                listStr = String(a.dropFirst("--fields=".count)); mode = .fields
                i += 1; continue
            }
            if a == "-c" || a == "--characters" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("cut: -c requires LIST\n"); return ExitStatus(2)
                }
                listStr = rawArgv[i + 1]; mode = .chars; i += 2; continue
            }
            if a.hasPrefix("--characters=") {
                listStr = String(a.dropFirst("--characters=".count)); mode = .chars
                i += 1; continue
            }
            if a == "-b" || a == "--bytes" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("cut: -b requires LIST\n"); return ExitStatus(2)
                }
                listStr = rawArgv[i + 1]; mode = .bytes; i += 2; continue
            }
            if a.hasPrefix("--bytes=") {
                listStr = String(a.dropFirst("--bytes=".count)); mode = .bytes
                i += 1; continue
            }
            if a == "-d" || a == "--delimiter" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("cut: -d requires DELIM\n"); return ExitStatus(2)
                }
                delim = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("--delimiter=") {
                delim = String(a.dropFirst("--delimiter=".count)); i += 1; continue
            }
            if a.hasPrefix("--output-delimiter=") {
                outputDelim = String(a.dropFirst("--output-delimiter=".count))
                i += 1; continue
            }
            if a == "--output-delimiter" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("cut: --output-delimiter requires STR\n")
                    return ExitStatus(2)
                }
                outputDelim = rawArgv[i + 1]; i += 2; continue
            }
            if a == "-s" || a == "--only-delimited" {
                onlyDelimited = true; i += 1; continue
            }
            if a == "--complement" { complement = true; i += 1; continue }
            // Short form like -f1, -c1-3 etc. (concise GNU form).
            if a.hasPrefix("-") && a.count > 2,
               let kind = a.dropFirst().first,
               "fcb".contains(kind) {
                listStr = String(a.dropFirst(2))
                switch kind {
                case "f": mode = .fields
                case "c": mode = .chars
                case "b": mode = .bytes
                default: break
                }
                i += 1; continue
            }
            if a.hasPrefix("-d") && a.count > 2 {
                delim = String(a.dropFirst(2)); i += 1; continue
            }
            if a.hasPrefix("-") && a.count > 1 {
                Shell.bashCurrent.stderr("cut: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        guard let raw = listStr else {
            Shell.bashCurrent.stderr("cut: you must specify a list of bytes, characters, or fields\n")
            return ExitStatus(2)
        }
        let spec: FieldSpec
        do {
            spec = try FieldSpec.parse(raw)
        } catch let err as FieldSpec.ParseError {
            Shell.bashCurrent.stderr("cut: \(err.message)\n")
            return ExitStatus(2)
        }
        guard delim.count == 1 || mode != .fields else {
            Shell.bashCurrent.stderr("cut: -d requires a single character\n")
            return ExitStatus(2)
        }
        let delimChar = delim.first ?? "\t"
        let outDelim = outputDelim ?? String(delimChar)

        let useFiles = files.isEmpty ? ["-"] : files
        var hadError = false
        for f in useFiles {
            do {
                if f == "-" {
                    for await line in Shell.bashCurrent.stdin.lines {
                        try emit(line, mode: mode, spec: spec,
                                 delim: delimChar, outDelim: outDelim,
                                 onlyDelimited: onlyDelimited,
                                 complement: complement)
                    }
                } else {
                    let data = try await Shell.bashCurrent.readDataAtPath(f)
                    let text = String(decoding: data, as: UTF8.self)
                    for line in SortCommand.splitLines(text) {
                        try emit(line, mode: mode, spec: spec,
                                 delim: delimChar, outDelim: outDelim,
                                 onlyDelimited: onlyDelimited,
                                 complement: complement)
                    }
                }
            } catch {
                Shell.bashCurrent.stderr("cut: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func emit(_ line: String, mode: Mode, spec: FieldSpec,
                      delim: Character, outDelim: String,
                      onlyDelimited: Bool, complement: Bool) throws {
        switch mode {
        case .fields:
            if !line.contains(delim) {
                if onlyDelimited { return }
                Shell.bashCurrent.stdout(line + "\n"); return
            }
            let parts = line.split(separator: delim,
                                   omittingEmptySubsequences: false)
                .map(String.init)
            let picks = spec.picks(from: parts.count, complement: complement)
            Shell.bashCurrent.stdout(picks.map { parts[$0] }.joined(separator: outDelim) + "\n")
        case .chars:
            let chars = Array(line)
            let picks = spec.picks(from: chars.count, complement: complement)
            Shell.bashCurrent.stdout(String(picks.map { chars[$0] }) + "\n")
        case .bytes:
            let bytes = Array(line.utf8)
            let picks = spec.picks(from: bytes.count, complement: complement)
            let sliced = picks.map { bytes[$0] }
            Shell.bashCurrent.stdout(String(decoding: sliced, as: UTF8.self) + "\n")
        }
    }

    // MARK: Field/char/byte spec

    struct FieldSpec {
        struct ParseError: Error { let message: String }
        var ranges: [(lo: Int, hi: Int)]

        static func parse(_ raw: String) throws -> FieldSpec {
            var out: [(Int, Int)] = []
            for piece in raw.split(separator: ",") {
                let s = String(piece)
                if let dash = s.firstIndex(of: "-") {
                    let loStr = String(s[..<dash])
                    let hiStr = String(s[s.index(after: dash)...])
                    let lo = loStr.isEmpty ? 1 : (Int(loStr) ?? 0)
                    let hi = hiStr.isEmpty ? Int.max : (Int(hiStr) ?? 0)
                    guard lo >= 1, hi >= lo else {
                        throw ParseError(message: "invalid range `\(s)`")
                    }
                    out.append((lo, hi))
                } else {
                    guard let n = Int(s), n >= 1 else {
                        throw ParseError(message: "invalid field `\(s)`")
                    }
                    out.append((n, n))
                }
            }
            guard !out.isEmpty else { throw ParseError(message: "empty list") }
            return FieldSpec(ranges: out)
        }

        func picks(from count: Int, complement: Bool = false) -> [Int] {
            var keep = Array(repeating: false, count: count)
            for r in ranges {
                let lo = r.lo
                let hi = min(r.hi, count)
                if lo > hi { continue }
                for i in lo...hi { keep[i - 1] = true }
            }
            var out: [Int] = []
            for i in 0..<count {
                if keep[i] != complement { out.append(i) }
            }
            return out
        }
    }
}
