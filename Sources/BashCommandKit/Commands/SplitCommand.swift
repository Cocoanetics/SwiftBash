import ArgumentParser
import BashInterpreter
import Foundation

/// `split [OPTIONS] [FILE [PREFIX]]` — split a file into pieces.
///
/// - `-l N` / `--lines=N` — N lines per piece (default 1000)
/// - `-b SIZE` / `--bytes=SIZE` — fixed-size pieces. SIZE accepts
///   suffixes `b` (512) `K` (1024) `M` (1024²) `G` (1024³).
/// - `-a N` / `--suffix-length=N` — N alpha suffix chars (default 2,
///   yielding `aa`, `ab`, …, `zz`)
/// - `-d` / `--numeric-suffixes[=START]` — use digits instead of letters
/// - `--additional-suffix=STR` — append STR to each filename
///
/// FILE defaults to stdin (`-`); PREFIX defaults to `x`. Outputs are
/// written via the shell's filesystem.
public struct SplitCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Split a file into pieces."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then [FILE [PREFIX]].")
    public var rawArgv: [String] = []

    public init() {}

    private enum Mode { case lines(Int), bytes(Int) }

    // `split` defines ten distinct flag forms (short, long, `=value`);
    // each maps to its own branch in the parser.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var mode: Mode = .lines(1000)
        var suffixLen = 2
        var numeric = false
        var numericStart = 0
        var additional = ""
        var positionals: [String] = []

        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "--" {
                idx += 1
                while idx < rawArgv.count { positionals.append(rawArgv[idx]); idx += 1 }
                break
            }
            if arg == "-l" || arg == "--lines" {
                guard idx + 1 < rawArgv.count, let count = Int(rawArgv[idx + 1]), count > 0 else {
                    Shell.bashCurrent.stderr("split: -l requires positive N\n")
                    return ExitStatus(2)
                }
                mode = .lines(count); idx += 2; continue
            }
            if arg.hasPrefix("--lines=") {
                guard let count = Int(arg.dropFirst("--lines=".count)), count > 0 else {
                    Shell.bashCurrent.stderr("split: invalid --lines value\n")
                    return ExitStatus(2)
                }
                mode = .lines(count); idx += 1; continue
            }
            if arg == "-b" || arg == "--bytes" {
                guard idx + 1 < rawArgv.count, let size = parseSize(rawArgv[idx + 1]) else {
                    Shell.bashCurrent.stderr("split: -b requires SIZE\n")
                    return ExitStatus(2)
                }
                mode = .bytes(size); idx += 2; continue
            }
            if arg.hasPrefix("--bytes=") {
                guard let size = parseSize(String(arg.dropFirst("--bytes=".count))) else {
                    Shell.bashCurrent.stderr("split: invalid --bytes value\n")
                    return ExitStatus(2)
                }
                mode = .bytes(size); idx += 1; continue
            }
            if arg == "-a" || arg == "--suffix-length" {
                guard idx + 1 < rawArgv.count, let count = Int(rawArgv[idx + 1]), count > 0 else {
                    Shell.bashCurrent.stderr("split: -a requires positive N\n")
                    return ExitStatus(2)
                }
                suffixLen = count; idx += 2; continue
            }
            if arg.hasPrefix("--suffix-length=") {
                guard let count = Int(arg.dropFirst("--suffix-length=".count)), count > 0 else {
                    Shell.bashCurrent.stderr("split: invalid --suffix-length\n")
                    return ExitStatus(2)
                }
                suffixLen = count; idx += 1; continue
            }
            if arg == "-d" || arg == "--numeric-suffixes" {
                numeric = true; idx += 1; continue
            }
            if arg.hasPrefix("--numeric-suffixes=") {
                numeric = true
                if let start = Int(arg.dropFirst("--numeric-suffixes=".count)) {
                    numericStart = start
                }
                idx += 1; continue
            }
            if arg.hasPrefix("--additional-suffix=") {
                additional = String(arg.dropFirst("--additional-suffix=".count))
                idx += 1; continue
            }
            if arg == "--additional-suffix" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("split: --additional-suffix requires STR\n")
                    return ExitStatus(2)
                }
                additional = rawArgv[idx + 1]; idx += 2; continue
            }
            if arg.hasPrefix("-") && arg.count > 1 && arg != "-" {
                Shell.bashCurrent.stderr("split: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            positionals.append(arg); idx += 1
        }

        let inputPath = positionals.first ?? "-"
        let prefix = positionals.count > 1 ? positionals[1] : "x"

        let data: Data
        do {
            if inputPath == "-" {
                data = await Shell.bashCurrent.stdin.readAllData()
            } else {
                data = try await Shell.bashCurrent.readDataAtPath(inputPath)
            }
        } catch {
            Shell.bashCurrent.stderr("split: \(inputPath): \(error)\n")
            return ExitStatus(2)
        }

        let chunks: [Data]
        switch mode {
        case .lines(let count):
            chunks = splitByLines(data, count: count)
        case .bytes(let size):
            chunks = splitByBytes(data, size: size)
        }

        for (slot, chunk) in chunks.enumerated() {
            let suffix = makeSuffix(slot, length: suffixLen,
                                    numeric: numeric, start: numericStart)
            let path = prefix + suffix + additional
            do {
                try await Shell.bashCurrent.writeData(chunk, toPath: path, append: false)
            } catch {
                Shell.bashCurrent.stderr("split: \(path): \(error)\n")
                return .failure
            }
        }
        return .success
    }

    private func splitByLines(_ data: Data, count: Int) -> [Data] {
        var chunks: [Data] = []
        var current = Data()
        var lineCount = 0
        for byte in data {
            current.append(byte)
            if byte == 0x0A {
                lineCount += 1
                if lineCount == count {
                    chunks.append(current)
                    current = Data()
                    lineCount = 0
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func splitByBytes(_ data: Data, size: Int) -> [Data] {
        guard size > 0 else { return [data] }
        var chunks: [Data] = []
        var idx = 0
        while idx < data.count {
            let end = min(idx + size, data.count)
            chunks.append(data.subdata(in: idx..<end))
            idx = end
        }
        return chunks
    }

    private func parseSize(_ text: String) -> Int? {
        var rest = text
        var mult = 1
        if let last = rest.last {
            switch last {
            case "b": mult = 512;  rest.removeLast()
            case "K": mult = 1024; rest.removeLast()
            case "M": mult = 1024 * 1024; rest.removeLast()
            case "G": mult = 1024 * 1024 * 1024; rest.removeLast()
            default: break
            }
        }
        guard let value = Int(rest), value > 0 else { return nil }
        return value * mult
    }

    /// Build a suffix like `aa`, `ab`, …, or `00`, `01`, … depending
    /// on `numeric`. Length is the suffix-length option.
    private func makeSuffix(_ index: Int, length: Int,
                            numeric: Bool, start: Int) -> String {
        if numeric {
            let value = index + start
            return String(format: "%0\(length)d", value)
        }
        // Convert index to base-26 with `a` digits.
        var remaining = index
        var chars: [Character] = []
        for _ in 0..<length {
            let digit = remaining % 26
            chars.insert(Character(Unicode.Scalar(0x61 + UInt8(digit))), at: 0)
            remaining /= 26
        }
        return String(chars)
    }
}
