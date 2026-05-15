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

    /// Decoded argv with all `cut` options resolved.
    private struct ParsedOptions {
        var listStr: String?
        var mode: Mode = .fields
        var delim: String = "\t"
        var outputDelim: String?
        var onlyDelimited = false
        var complement = false
        var files: [String] = []
    }

    /// Bundle of per-line settings used by ``emit(_:options:)``.
    private struct EmitOptions {
        let mode: Mode
        let spec: FieldSpec
        let delim: Character
        let outDelim: String
        let onlyDelimited: Bool
        let complement: Bool
    }

    public mutating func execute() async throws -> ExitStatus {
        var options = ParsedOptions()
        if let earlyStatus = parseArgs(into: &options) { return earlyStatus }

        guard let raw = options.listStr else {
            Shell.bashCurrent.stderr(
                "cut: you must specify a list of bytes, characters, or fields\n")
            return ExitStatus(2)
        }
        let spec: FieldSpec
        do {
            spec = try FieldSpec.parse(raw)
        } catch let err as FieldSpec.ParseError {
            Shell.bashCurrent.stderr("cut: \(err.message)\n")
            return ExitStatus(2)
        }
        guard options.delim.count == 1 || options.mode != .fields else {
            Shell.bashCurrent.stderr("cut: -d requires a single character\n")
            return ExitStatus(2)
        }
        let delimChar = options.delim.first ?? "\t"
        let emitOptions = EmitOptions(
            mode: options.mode, spec: spec, delim: delimChar,
            outDelim: options.outputDelim ?? String(delimChar),
            onlyDelimited: options.onlyDelimited,
            complement: options.complement)
        return try await runFiles(options.files, emitOptions: emitOptions)
    }

    private func runFiles(_ files: [String],
                          emitOptions: EmitOptions) async throws -> ExitStatus {
        let useFiles = files.isEmpty ? ["-"] : files
        var hadError = false
        for file in useFiles {
            do {
                try await processFile(file, emitOptions: emitOptions)
            } catch {
                Shell.bashCurrent.stderr("cut: \(file): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func processFile(_ file: String,
                             emitOptions: EmitOptions) async throws {
        if file == "-" {
            for await line in Shell.bashCurrent.stdin.lines {
                try emit(line, options: emitOptions)
            }
        } else {
            let data = try await Shell.bashCurrent.readDataAtPath(file)
            // cut runs through arbitrary input, including potentially
            // non-UTF-8 binary; lossy decode keeps the pipeline alive.
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: data, as: UTF8.self)
            for line in SortCommand.splitLines(text) {
                try emit(line, options: emitOptions)
            }
        }
    }

    // Combined argv decoder — the long if/else chain stays
    // readable inline; splitting per-flag would duplicate the
    // `continue`/`return ExitStatus(2)` control flow.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private mutating func parseArgs(into options: inout ParsedOptions) -> ExitStatus? {
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count {
                    options.files.append(rawArgv[index])
                    index += 1
                }
                break
            }
            if arg == "-" {
                options.files.append("-")
                index += 1
                continue
            }
            if let status = handleListFlag(arg, index: &index, options: &options) {
                if case .handled = status { continue }
                return ExitStatus(2)
            }
            if let status = handleDelimFlag(arg, index: &index, options: &options) {
                if case .handled = status { continue }
                return ExitStatus(2)
            }
            if arg == "-s" || arg == "--only-delimited" {
                options.onlyDelimited = true
                index += 1
                continue
            }
            if arg == "--complement" {
                options.complement = true
                index += 1
                continue
            }
            // Concise GNU short form: -f1, -c1-3, -b1-5.
            if arg.hasPrefix("-") && arg.count > 2,
               let kind = arg.dropFirst().first,
               "fcb".contains(kind) {
                options.listStr = String(arg.dropFirst(2))
                switch kind {
                case "f": options.mode = .fields
                case "c": options.mode = .chars
                case "b": options.mode = .bytes
                default: break
                }
                index += 1
                continue
            }
            if arg.hasPrefix("-d") && arg.count > 2 {
                options.delim = String(arg.dropFirst(2))
                index += 1
                continue
            }
            if arg.hasPrefix("-") && arg.count > 1 {
                Shell.bashCurrent.stderr("cut: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            options.files.append(arg)
            index += 1
        }
        return nil
    }

    private enum FlagResult {
        case handled
        case error
    }

    private struct ListFlagMapping {
        let short: String
        let long: String
        let mode: Mode
        let prefix: String
    }

    private func handleListFlag(_ arg: String,
                                index: inout Int,
                                options: inout ParsedOptions) -> FlagResult? {
        let mappings: [ListFlagMapping] = [
            ListFlagMapping(short: "-f", long: "--fields",
                            mode: .fields, prefix: "--fields="),
            ListFlagMapping(short: "-c", long: "--characters",
                            mode: .chars, prefix: "--characters="),
            ListFlagMapping(short: "-b", long: "--bytes",
                            mode: .bytes, prefix: "--bytes=")
        ]
        for mapping in mappings {
            if arg == mapping.short || arg == mapping.long {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr(
                        "cut: \(mapping.short) requires LIST\n")
                    return .error
                }
                options.listStr = rawArgv[index + 1]
                options.mode = mapping.mode
                index += 2
                return .handled
            }
            if arg.hasPrefix(mapping.prefix) {
                options.listStr = String(arg.dropFirst(mapping.prefix.count))
                options.mode = mapping.mode
                index += 1
                return .handled
            }
        }
        return nil
    }

    private func handleDelimFlag(_ arg: String,
                                 index: inout Int,
                                 options: inout ParsedOptions) -> FlagResult? {
        if arg == "-d" || arg == "--delimiter" {
            guard index + 1 < rawArgv.count else {
                Shell.bashCurrent.stderr("cut: -d requires DELIM\n")
                return .error
            }
            options.delim = rawArgv[index + 1]
            index += 2
            return .handled
        }
        if arg.hasPrefix("--delimiter=") {
            options.delim = String(arg.dropFirst("--delimiter=".count))
            index += 1
            return .handled
        }
        if arg.hasPrefix("--output-delimiter=") {
            options.outputDelim = String(arg.dropFirst("--output-delimiter=".count))
            index += 1
            return .handled
        }
        if arg == "--output-delimiter" {
            guard index + 1 < rawArgv.count else {
                Shell.bashCurrent.stderr("cut: --output-delimiter requires STR\n")
                return .error
            }
            options.outputDelim = rawArgv[index + 1]
            index += 2
            return .handled
        }
        return nil
    }

    private func emit(_ line: String, options: EmitOptions) throws {
        switch options.mode {
        case .fields:
            if !line.contains(options.delim) {
                if options.onlyDelimited { return }
                Shell.bashCurrent.stdout(line + "\n")
                return
            }
            let parts = line.split(separator: options.delim,
                                   omittingEmptySubsequences: false)
                .map(String.init)
            let picks = options.spec.picks(
                from: parts.count, complement: options.complement)
            Shell.bashCurrent.stdout(
                picks.map { parts[$0] }.joined(separator: options.outDelim) + "\n")
        case .chars:
            let chars = Array(line)
            let picks = options.spec.picks(
                from: chars.count, complement: options.complement)
            Shell.bashCurrent.stdout(String(picks.map { chars[$0] }) + "\n")
        case .bytes:
            let bytes = Array(line.utf8)
            let picks = options.spec.picks(
                from: bytes.count, complement: options.complement)
            let sliced = picks.map { bytes[$0] }
            // Slicing raw UTF-8 bytes can leave partial code units;
            // a lossy decode produces the same output GNU cut does.
            // swiftlint:disable:next optional_data_string_conversion
            Shell.bashCurrent.stdout(String(decoding: sliced, as: UTF8.self) + "\n")
        }
    }

}

// MARK: Field/char/byte spec

/// 1-based slice spec parsed from `cut -f`, `-c`, `-b`.
///
/// Lives at file scope so `FieldSpec.Range` and `FieldSpec.ParseError`
/// don't end up nested two levels deep inside `CutCommand`.
struct FieldSpec {
    struct ParseError: Error { let message: String }

    struct Range {
        let low: Int
        let high: Int
    }

    var ranges: [Range]

    static func parse(_ raw: String) throws -> FieldSpec {
        var out: [Range] = []
        for piece in raw.split(separator: ",") {
            let segment = String(piece)
            if let dash = segment.firstIndex(of: "-") {
                let loStr = String(segment[..<dash])
                let hiStr = String(segment[segment.index(after: dash)...])
                let low = loStr.isEmpty ? 1 : (Int(loStr) ?? 0)
                let high = hiStr.isEmpty ? Int.max : (Int(hiStr) ?? 0)
                guard low >= 1, high >= low else {
                    throw ParseError(message: "invalid range `\(segment)`")
                }
                out.append(Range(low: low, high: high))
            } else {
                guard let number = Int(segment), number >= 1 else {
                    throw ParseError(message: "invalid field `\(segment)`")
                }
                out.append(Range(low: number, high: number))
            }
        }
        guard !out.isEmpty else { throw ParseError(message: "empty list") }
        return FieldSpec(ranges: out)
    }

    func picks(from count: Int, complement: Bool = false) -> [Int] {
        var keep = Array(repeating: false, count: count)
        for range in ranges {
            let low = range.low
            let high = min(range.high, count)
            if low > high { continue }
            for idx in low...high { keep[idx - 1] = true }
        }
        var out: [Int] = []
        for idx in 0..<count where keep[idx] != complement {
            out.append(idx)
        }
        return out
    }
}
