import ArgumentParser
import BashInterpreter
import Foundation

/// `fold [-w WIDTH] [-s] [-b] [FILE...]` — wrap lines.
///
/// - `-w N` / `--width=N` — wrap at N columns (default 80)
/// - `-s` / `--spaces` — break at spaces only
/// - `-b` / `--bytes` — count bytes instead of columns
public struct FoldCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "fold",
        abstract: "Wrap lines."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var parsed: ParsedArgs
        switch parseArgs() {
        case .success(let args): parsed = args
        case .failure(let code): return code
        }
        let width = parsed.width
        let atSpaces = parsed.atSpaces
        let byBytes = parsed.byBytes
        let files = parsed.files

        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for file in inputs {
            try Task.checkCancellation()
            do {
                let text: String
                if file == "-" {
                    text = await Shell.bashCurrent.stdin.readAllString()
                } else {
                    let data = try await Shell.bashCurrent.readDataAtPath(file)
                    // swiftlint:disable:next optional_data_string_conversion
                    text = String(decoding: data, as: UTF8.self)
                }
                Shell.bashCurrent.stdout(FoldCommand.fold(text, width: width,
                                                          atSpaces: atSpaces, byBytes: byBytes))
            } catch {
                Shell.bashCurrent.stderr("fold: \(file): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private struct ParsedArgs {
        var width: Int
        var atSpaces: Bool
        var byBytes: Bool
        var files: [String]
    }

    private enum ArgResult {
        case success(ParsedArgs)
        case failure(ExitStatus)
    }

    // Argv loop: walks long-form / short / bundled width specs. Each
    // option arm sets one parsed field; per-flag helpers would just
    // forward to the same parser locals.
    // swiftlint:disable:next cyclomatic_complexity
    private func parseArgs() -> ArgResult {
        var width = 80
        var atSpaces = false
        var byBytes = false
        var files: [String] = []
        var index = 0
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if arg == "--" {
                index += 1
                while index < rawArgv.count { files.append(rawArgv[index]); index += 1 }
                break
            }
            if arg == "-s" || arg == "--spaces" { atSpaces = true; index += 1; continue }
            if arg == "-b" || arg == "--bytes" { byBytes = true; index += 1; continue }
            if arg == "-w" || arg == "--width" {
                guard index + 1 < rawArgv.count, let parsedW = Int(rawArgv[index + 1]), parsedW > 0 else {
                    Shell.bashCurrent.stderr("fold: -w requires WIDTH\n"); return .failure(ExitStatus(2))
                }
                width = parsedW; index += 2; continue
            }
            if arg.hasPrefix("--width=") {
                guard let parsedW = Int(arg.dropFirst("--width=".count)), parsedW > 0 else {
                    Shell.bashCurrent.stderr("fold: invalid --width\n"); return .failure(ExitStatus(2))
                }
                width = parsedW; index += 1; continue
            }
            if arg.hasPrefix("-") && arg.count > 1 && arg != "-" {
                if let parsedW = Int(arg.dropFirst()) { width = parsedW; index += 1; continue }
                Shell.bashCurrent.stderr("fold: unknown option: \(arg)\n"); return .failure(ExitStatus(2))
            }
            files.append(arg); index += 1
        }
        return .success(ParsedArgs(width: width, atSpaces: atSpaces, byBytes: byBytes, files: files))
    }

    static func fold(_ text: String, width: Int, atSpaces: Bool, byBytes: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        let inputEndsNL = !lines.isEmpty && lines.last == ""
        if inputEndsNL { lines.removeLast() }
        var out = ""
        for line in lines {
            var remaining = line
            while !remaining.isEmpty {
                let units = byBytes ? remaining.utf8.count : remaining.count
                if units <= width {
                    out += remaining + "\n"; break
                }
                var splitAt = width
                if atSpaces {
                    // Find last space at or before `width`.
                    let chars = Array(remaining)
                    var found: Int?
                    for idx in (0..<min(width, chars.count)).reversed() where chars[idx] == " " {
                        found = idx + 1; break
                    }
                    if let foundIdx = found, foundIdx > 0 { splitAt = foundIdx }
                }
                let chars = Array(remaining)
                let head = String(chars[..<splitAt])
                let tail = String(chars[splitAt...])
                out += head + "\n"
                remaining = tail
            }
        }
        if !inputEndsNL && out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
