import ArgumentParser
import BashInterpreter
import Foundation

/// `tail [-n N] [-c B] [-q|-v] [-NUM] [+N] [FILE...]` — print the last
/// portion of each file (or stdin when no files are given).
///
/// - `-n N`, `-n +N` — last N lines (or starting from line N when prefixed `+`)
/// - `-NUM` — shorthand for `-n NUM`
/// - `-c B` — last B bytes
/// - `-q` / `-v` — suppress / force the `==> name <==` headers
public struct TailCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Print the last lines or bytes of input."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then FILE arguments.")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var lines: Int = 10
        var bytes: Int? = nil
        // `+N` semantics: skip the first N-1 lines / bytes and print the rest.
        // We track the sign by whether `linesFromStart` is set.
        var linesFromStart: Int? = nil
        var bytesFromStart: Int? = nil
        var headerMode: HeaderMode = .auto
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "--" {
                i += 1
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                break
            }
            // Options.
            if a == "-n" || a == "--lines" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("tail: option requires an argument: \(a)\n")
                    return ExitStatus(2)
                }
                if let (n, fromStart) = parseCount(rawArgv[i + 1]) {
                    if fromStart { linesFromStart = n } else { lines = n }
                } else {
                    shell.stderr("tail: invalid number: \(rawArgv[i + 1])\n")
                    return ExitStatus(2)
                }
                i += 2; continue
            }
            if a == "-c" || a == "--bytes" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("tail: option requires an argument: \(a)\n")
                    return ExitStatus(2)
                }
                if let (n, fromStart) = parseCount(rawArgv[i + 1]) {
                    if fromStart { bytesFromStart = n } else { bytes = n }
                } else {
                    shell.stderr("tail: invalid number: \(rawArgv[i + 1])\n")
                    return ExitStatus(2)
                }
                i += 2; continue
            }
            if a == "-q" || a == "--quiet" || a == "--silent" {
                headerMode = .never; i += 1; continue
            }
            if a == "-v" || a == "--verbose" {
                headerMode = .always; i += 1; continue
            }
            // `-NUM` and `+NUM` shorthands.
            if a.hasPrefix("-"), a.count > 1,
               let (n, _) = parseCount(String(a.dropFirst())),
               isNumeric(String(a.dropFirst()))
            {
                lines = n; i += 1; continue
            }
            if a.hasPrefix("+"), let n = Int(a.dropFirst()) {
                linesFromStart = n; i += 1; continue
            }
            // Anything else: file argument.
            files.append(a); i += 1
        }

        let useHeaders: Bool
        switch headerMode {
        case .always: useHeaders = true
        case .never: useHeaders = false
        case .auto: useHeaders = files.count > 1
        }

        if files.isEmpty {
            let data = await readAll(stdin: shell.stdin)
            emitTail(data: data, lines: lines, bytes: bytes,
                     linesFromStart: linesFromStart,
                     bytesFromStart: bytesFromStart, shell: shell)
            return .success
        }

        var hadError = false
        for (idx, path) in files.enumerated() {
            if useHeaders {
                if idx > 0 { shell.stdout("\n") }
                shell.stdout("==> \(path) <==\n")
            }
            do {
                let data: Data
                if path == "-" { data = await readAll(stdin: shell.stdin) }
                else { data = try await shell.readDataAtPath(path) }
                emitTail(data: data, lines: lines, bytes: bytes,
                         linesFromStart: linesFromStart,
                         bytesFromStart: bytesFromStart, shell: shell)
            } catch FileSystemError.notFound {
                shell.stderr("tail: \(path): No such file or directory\n")
                hadError = true
            } catch FileSystemError.isADirectory {
                shell.stderr("tail: \(path): Is a directory\n")
                hadError = true
            } catch {
                shell.stderr("tail: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private enum HeaderMode { case auto, always, never }

    /// Parse `N`, `+N`, or `-N` into `(absolute count, fromStart)`.
    private func parseCount(_ s: String) -> (Int, Bool)? {
        if s.hasPrefix("+"), let n = Int(s.dropFirst()) { return (n, true) }
        if let n = Int(s) { return (abs(n), false) }
        return nil
    }

    private func isNumeric(_ s: String) -> Bool {
        return !s.isEmpty && s.allSatisfy { $0.isNumber }
    }

    private func readAll(stdin: InputSource) async -> Data {
        var out = Data()
        for await chunk in stdin.bytes { out.append(chunk) }
        return out
    }

    private func emitTail(data: Data,
                          lines: Int, bytes: Int?,
                          linesFromStart: Int?,
                          bytesFromStart: Int?,
                          shell: Shell)
    {
        if let bf = bytesFromStart {
            // bash: `+N` means "starting at byte N" (1-indexed).
            let start = max(0, bf - 1)
            if start < data.count { shell.stdout(data.suffix(from: start)) }
            return
        }
        if let b = bytes {
            shell.stdout(data.suffix(b))
            return
        }
        if data.isEmpty { return }
        let text = String(decoding: data, as: UTF8.self)
        var split = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
        if text.hasSuffix("\n"), !split.isEmpty { split.removeLast() }

        if let lf = linesFromStart {
            let start = max(0, lf - 1)
            if start < split.count {
                for line in split[start...] { shell.stdout(line + "\n") }
            }
            return
        }
        let tailLines = split.count > lines
            ? Array(split.suffix(lines)) : split
        for line in tailLines { shell.stdout(line + "\n") }
    }
}
