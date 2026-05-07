import ArgumentParser
import BashInterpreter
import Foundation

/// `head [OPTIONS] [FILE...]` — print the leading lines or bytes of
/// each input.
///
/// Supported flags:
/// - `-n N` / `--lines=N` — print first N lines (default 10).
///   `-n -K` (negative) prints all lines but the last K.
/// - `-c BYTES` / `--bytes=BYTES` — print first BYTES bytes.
///   Negative form prints all but the last K bytes.
/// - `-q` / `--quiet` — never print headers, even with multiple files
/// - `-v` / `--verbose` — always print headers, even with one file
///
/// With multiple FILEs, head prints `==> NAME <==` headers between
/// them by default. With no FILE (or `-`), reads stdin.
public struct HeadCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "head",
        abstract: "Print the leading lines or bytes of each input."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var lines: Int? = 10
        var bytes: Int? = nil
        // Negative limits ("-n -3") mean "all except the last K".
        var linesTrailing = false
        var bytesTrailing = false
        var quiet = false
        var verbose = false
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
            if a == "-q" || a == "--quiet" || a == "--silent" {
                quiet = true; i += 1; continue
            }
            if a == "-v" || a == "--verbose" {
                verbose = true; i += 1; continue
            }
            if a == "-n" || a == "--lines" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("head: -n requires N\n"); return ExitStatus(2)
                }
                let (n, trailing) = try parseSignedCount(rawArgv[i + 1])
                lines = n; linesTrailing = trailing; bytes = nil
                i += 2; continue
            }
            if a.hasPrefix("--lines=") {
                let (n, trailing) = try parseSignedCount(String(a.dropFirst("--lines=".count)))
                lines = n; linesTrailing = trailing; bytes = nil
                i += 1; continue
            }
            if a == "-c" || a == "--bytes" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("head: -c requires BYTES\n"); return ExitStatus(2)
                }
                let (n, trailing) = try parseSignedCount(rawArgv[i + 1])
                bytes = n; bytesTrailing = trailing; lines = nil
                i += 2; continue
            }
            if a.hasPrefix("--bytes=") {
                let (n, trailing) = try parseSignedCount(String(a.dropFirst("--bytes=".count)))
                bytes = n; bytesTrailing = trailing; lines = nil
                i += 1; continue
            }
            // -nN — historical "leading-digit" short form (e.g., -5).
            if a.count > 1, a.hasPrefix("-"),
               let firstDigit = a.dropFirst().first, firstDigit.isNumber || firstDigit == "+" || firstDigit == "-" {
                let (n, trailing) = try parseSignedCount(String(a.dropFirst()))
                lines = n; linesTrailing = trailing; bytes = nil
                i += 1; continue
            }
            if a.hasPrefix("-") && a != "-" {
                Shell.bashCurrent.stderr("head: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
        }

        let useFiles = files.isEmpty ? ["-"] : files
        let multiple = useFiles.count > 1
        let printHeaders = verbose || (multiple && !quiet)

        var hadError = false
        for (idx, f) in useFiles.enumerated() {
            if printHeaders {
                if idx > 0 { Shell.bashCurrent.stdout("\n") }
                let label = (f == "-") ? "standard input" : f
                Shell.bashCurrent.stdout("==> \(label) <==\n")
            }
            do {
                if let n = lines {
                    try await emitLines(f, count: n, trailing: linesTrailing)
                } else if let n = bytes {
                    try await emitBytes(f, count: n, trailing: bytesTrailing)
                }
            } catch {
                Shell.bashCurrent.stderr("head: \(f): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    /// Parse `N`, `-N`, `+N` for `-n` and `-c`. Returns `(count, trailing)`
    /// where `trailing` is true for the "all-but-last-K" form.
    private func parseSignedCount(_ s: String) throws -> (Int, Bool) {
        var rest = s
        var trailing = false
        if rest.first == "-" { trailing = true; rest.removeFirst() }
        else if rest.first == "+" { rest.removeFirst() }
        guard let n = Int(rest) else {
            throw ValidationError("head: invalid count: \(s)")
        }
        return (n, trailing)
    }

    // MARK: Line mode

    private func emitLines(_ path: String, count: Int, trailing: Bool) async throws {
        if trailing {
            // All-but-last-K: need to buffer the last K lines and emit
            // everything older. Stream-friendly with a sliding window.
            if count <= 0 {
                try await streamAllLines(path)
                return
            }
            var window: [String] = []
            window.reserveCapacity(count)
            try await forEachLine(path: path) { line in
                if window.count == count {
                    Shell.bashCurrent.stdout(window.removeFirst() + "\n")
                }
                window.append(line)
            }
            return
        }
        if count <= 0 { return }
        var emitted = 0
        try await forEachLine(path: path) { line in
            Shell.bashCurrent.stdout(line + "\n")
            emitted += 1
            if emitted >= count { throw HeadDone() }
        }
    }

    private func streamAllLines(_ path: String) async throws {
        try await forEachLine(path: path) { line in
            Shell.bashCurrent.stdout(line + "\n")
        }
    }

    private func forEachLine(path: String, 
                             _ body: (String) throws -> Void) async throws {
        if path == "-" {
            for await line in Shell.bashCurrent.stdin.lines {
                do { try body(line) } catch is HeadDone { return }
            }
            return
        }
        let source = try await Shell.bashCurrent.openInputPath(path)
        for await line in source.lines {
            do { try body(line) } catch is HeadDone { return }
        }
    }

    // MARK: Byte mode

    private func emitBytes(_ path: String, count: Int, trailing: Bool) async throws {
        // Byte mode buffers a Data; cheap for typical inputs and avoids
        // the partial-utf8 worries of the chunked path.
        let data: Data
        if path == "-" {
            data = await Shell.bashCurrent.stdin.readAllData()
        } else {
            data = try await Shell.bashCurrent.readDataAtPath(path)
        }
        if trailing {
            if count <= 0 { Shell.bashCurrent.stdout(data); return }
            let end = max(0, data.count - count)
            Shell.bashCurrent.stdout(data.prefix(end))
            return
        }
        if count <= 0 { return }
        Shell.bashCurrent.stdout(data.prefix(count))
    }

    private struct HeadDone: Error {}
}
