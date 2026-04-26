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

    public mutating func execute() async throws -> ExitStatus {
        var mode: Mode = .lines(1000)
        var suffixLen = 2
        var numeric = false
        var numericStart = 0
        var additional = ""
        var positionals: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { positionals.append(rawArgv[i]); i += 1 }
                break
            }
            if a == "-l" || a == "--lines" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n > 0 else {
                    Shell.current.stderr("split: -l requires positive N\n"); return ExitStatus(2)
                }
                mode = .lines(n); i += 2; continue
            }
            if a.hasPrefix("--lines=") {
                guard let n = Int(a.dropFirst("--lines=".count)), n > 0 else {
                    Shell.current.stderr("split: invalid --lines value\n"); return ExitStatus(2)
                }
                mode = .lines(n); i += 1; continue
            }
            if a == "-b" || a == "--bytes" {
                guard i + 1 < rawArgv.count, let n = parseSize(rawArgv[i + 1]) else {
                    Shell.current.stderr("split: -b requires SIZE\n"); return ExitStatus(2)
                }
                mode = .bytes(n); i += 2; continue
            }
            if a.hasPrefix("--bytes=") {
                guard let n = parseSize(String(a.dropFirst("--bytes=".count))) else {
                    Shell.current.stderr("split: invalid --bytes value\n"); return ExitStatus(2)
                }
                mode = .bytes(n); i += 1; continue
            }
            if a == "-a" || a == "--suffix-length" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]), n > 0 else {
                    Shell.current.stderr("split: -a requires positive N\n"); return ExitStatus(2)
                }
                suffixLen = n; i += 2; continue
            }
            if a.hasPrefix("--suffix-length=") {
                guard let n = Int(a.dropFirst("--suffix-length=".count)), n > 0 else {
                    Shell.current.stderr("split: invalid --suffix-length\n"); return ExitStatus(2)
                }
                suffixLen = n; i += 1; continue
            }
            if a == "-d" || a == "--numeric-suffixes" {
                numeric = true; i += 1; continue
            }
            if a.hasPrefix("--numeric-suffixes=") {
                numeric = true
                if let n = Int(a.dropFirst("--numeric-suffixes=".count)) {
                    numericStart = n
                }
                i += 1; continue
            }
            if a.hasPrefix("--additional-suffix=") {
                additional = String(a.dropFirst("--additional-suffix=".count))
                i += 1; continue
            }
            if a == "--additional-suffix" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("split: --additional-suffix requires STR\n")
                    return ExitStatus(2)
                }
                additional = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                Shell.current.stderr("split: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            positionals.append(a); i += 1
        }

        let inputPath = positionals.first ?? "-"
        let prefix = positionals.count > 1 ? positionals[1] : "x"

        let data: Data
        do {
            if inputPath == "-" {
                data = await Shell.current.stdin.readAllData()
            } else {
                data = try await Shell.current.readDataAtPath(inputPath)
            }
        } catch {
            Shell.current.stderr("split: \(inputPath): \(error)\n")
            return ExitStatus(2)
        }

        let chunks: [Data]
        switch mode {
        case .lines(let n):
            chunks = splitByLines(data, n: n)
        case .bytes(let n):
            chunks = splitByBytes(data, n: n)
        }

        for (idx, chunk) in chunks.enumerated() {
            let suffix = makeSuffix(idx, length: suffixLen,
                                    numeric: numeric, start: numericStart)
            let path = prefix + suffix + additional
            do {
                try await Shell.current.writeData(chunk, toPath: path, append: false)
            } catch {
                Shell.current.stderr("split: \(path): \(error)\n")
                return .failure
            }
        }
        return .success
    }

    private func splitByLines(_ data: Data, n: Int) -> [Data] {
        var chunks: [Data] = []
        var current = Data()
        var lineCount = 0
        for byte in data {
            current.append(byte)
            if byte == 0x0A {
                lineCount += 1
                if lineCount == n {
                    chunks.append(current)
                    current = Data()
                    lineCount = 0
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func splitByBytes(_ data: Data, n: Int) -> [Data] {
        guard n > 0 else { return [data] }
        var chunks: [Data] = []
        var idx = 0
        while idx < data.count {
            let end = min(idx + n, data.count)
            chunks.append(data.subdata(in: idx..<end))
            idx = end
        }
        return chunks
    }

    private func parseSize(_ s: String) -> Int? {
        var rest = s
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
        guard let n = Int(rest), n > 0 else { return nil }
        return n * mult
    }

    /// Build a suffix like `aa`, `ab`, …, or `00`, `01`, … depending
    /// on `numeric`. Length is the suffix-length option.
    private func makeSuffix(_ index: Int, length: Int,
                            numeric: Bool, start: Int) -> String {
        if numeric {
            let n = index + start
            return String(format: "%0\(length)d", n)
        }
        // Convert index to base-26 with `a` digits.
        var n = index
        var chars: [Character] = []
        for _ in 0..<length {
            let digit = n % 26
            chars.insert(Character(Unicode.Scalar(0x61 + UInt8(digit))), at: 0)
            n /= 26
        }
        return String(chars)
    }
}
