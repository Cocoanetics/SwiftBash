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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var lines: Int = 10
        var bytes: Int?
        // `+N` semantics: skip the first N-1 lines / bytes and print the rest.
        // We track the sign by whether `linesFromStart` is set.
        var linesFromStart: Int?
        var bytesFromStart: Int?
        var headerMode: HeaderMode = .auto
        var files: [String] = []

        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { files.append(rawArgv[index]); index += 1 }
                break
            }
            // Options.
            if arg == "-n" || arg == "--lines" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("tail: option requires an argument: \(arg)\n")
                    return ExitStatus(2)
                }
                if let (count, fromStart) = parseCount(rawArgv[index + 1]) {
                    if fromStart { linesFromStart = count } else { lines = count }
                } else {
                    Shell.bashCurrent.stderr("tail: invalid number: \(rawArgv[index + 1])\n")
                    return ExitStatus(2)
                }
                index += 2; continue
            }
            if arg == "-c" || arg == "--bytes" {
                guard index + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("tail: option requires an argument: \(arg)\n")
                    return ExitStatus(2)
                }
                if let (count, fromStart) = parseCount(rawArgv[index + 1]) {
                    if fromStart { bytesFromStart = count } else { bytes = count }
                } else {
                    Shell.bashCurrent.stderr("tail: invalid number: \(rawArgv[index + 1])\n")
                    return ExitStatus(2)
                }
                index += 2; continue
            }
            if arg == "-q" || arg == "--quiet" || arg == "--silent" {
                headerMode = .never; index += 1; continue
            }
            if arg == "-v" || arg == "--verbose" {
                headerMode = .always; index += 1; continue
            }
            // `-NUM` and `+NUM` shorthands.
            if arg.hasPrefix("-"), arg.count > 1,
               let (count, _) = parseCount(String(arg.dropFirst())),
               isNumeric(String(arg.dropFirst())) {
                lines = count; index += 1; continue
            }
            if arg.hasPrefix("+"), let count = Int(arg.dropFirst()) {
                linesFromStart = count; index += 1; continue
            }
            // Anything else: file argument.
            files.append(arg); index += 1
        }

        let useHeaders: Bool
        switch headerMode {
        case .always: useHeaders = true
        case .never: useHeaders = false
        case .auto: useHeaders = files.count > 1
        }

        if files.isEmpty {
            let data = await readAll(stdin: Shell.bashCurrent.stdin)
            emitTail(data: data, lines: lines, bytes: bytes,
                     linesFromStart: linesFromStart,
                     bytesFromStart: bytesFromStart)
            return .success
        }

        var hadError = false
        for (idx, path) in files.enumerated() {
            if useHeaders {
                if idx > 0 { Shell.bashCurrent.stdout("\n") }
                Shell.bashCurrent.stdout("==> \(path) <==\n")
            }
            do {
                let data: Data
                if path == "-" {
                    data = await readAll(stdin: Shell.bashCurrent.stdin)
                } else {
                    data = try await Shell.bashCurrent.readDataAtPath(path)
                }
                emitTail(data: data, lines: lines, bytes: bytes,
                         linesFromStart: linesFromStart,
                         bytesFromStart: bytesFromStart)
            } catch FileSystemError.notFound {
                Shell.bashCurrent.stderr("tail: \(path): No such file or directory\n")
                hadError = true
            } catch FileSystemError.isADirectory {
                Shell.bashCurrent.stderr("tail: \(path): Is a directory\n")
                hadError = true
            } catch {
                Shell.bashCurrent.stderr("tail: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private enum HeaderMode { case auto, always, never }

    /// Parse `N`, `+N`, or `-N` into `(absolute count, fromStart)`.
    private func parseCount(_ source: String) -> (Int, Bool)? {
        if source.hasPrefix("+"), let count = Int(source.dropFirst()) { return (count, true) }
        if let count = Int(source) { return (abs(count), false) }
        return nil
    }

    private func isNumeric(_ source: String) -> Bool {
        return !source.isEmpty && source.allSatisfy { $0.isNumber }
    }

    private func readAll(stdin: InputSource) async -> Data {
        var out = Data()
        for await chunk in stdin.bytes { out.append(chunk) }
        return out
    }

    private func emitTail(data: Data,
                          lines: Int, bytes: Int?,
                          linesFromStart: Int?,
                          bytesFromStart: Int?) {
        if let bytesFromStart {
            // bash: `+N` means "starting at byte N" (1-indexed).
            let start = max(0, bytesFromStart - 1)
            if start < data.count { Shell.bashCurrent.stdout(data.suffix(from: start)) }
            return
        }
        if let bytes {
            Shell.bashCurrent.stdout(data.suffix(bytes))
            return
        }
        if data.isEmpty { return }
        // swiftlint:disable:next optional_data_string_conversion - tail may receive partial UTF-8
        let text = String(decoding: data, as: UTF8.self)
        var split = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
        if text.hasSuffix("\n"), !split.isEmpty { split.removeLast() }

        if let linesFromStart {
            let start = max(0, linesFromStart - 1)
            if start < split.count {
                for line in split[start...] { Shell.bashCurrent.stdout(line + "\n") }
            }
            return
        }
        let tailLines = split.count > lines
            ? Array(split.suffix(lines)) : split
        for line in tailLines { Shell.bashCurrent.stdout(line + "\n") }
    }
}
