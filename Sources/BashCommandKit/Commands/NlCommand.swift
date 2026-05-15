import ArgumentParser
import BashInterpreter
import Foundation

/// `nl [-b TYPE] [-w N] [-s STR] [-v N] [FILE...]` — number lines and
/// write to stdout. By default only non-empty lines are numbered;
/// unnumbered lines pass through unchanged.
///
/// Body styles:
/// - `a` — number every line
/// - `t` — number non-empty lines only (default)
/// - `n` — never number lines
///
/// Hand-parses argv so combined short forms (`-ba`, `-bn`, `-w4`)
/// work the way real `nl` accepts them.
public struct NlCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "nl",
        abstract: "Number lines and write them to stdout."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    private enum BodyStyle { case all, nonEmpty, off }

    // `nl` accepts eight flag variants (short, combined, `=value`); the
    // dispatch table is intrinsically wide.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var style: BodyStyle = .nonEmpty
        var width = 6
        var separator = "\t"
        var counter = 1
        var files: [String] = []

        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "--" {
                idx += 1
                while idx < rawArgv.count { files.append(rawArgv[idx]); idx += 1 }
                break
            }
            if arg == "-" { files.append("-"); idx += 1; continue }
            if arg == "-b" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("nl: -b requires TYPE\n"); return ExitStatus(2)
                }
                guard let parsed = parseStyle(rawArgv[idx + 1]) else {
                    Shell.bashCurrent.stderr("nl: invalid body numbering style: "
                                             + "'\(rawArgv[idx + 1])'\n")
                    return ExitStatus(2)
                }
                style = parsed; idx += 2; continue
            }
            if arg.hasPrefix("-b") && arg.count > 2 {
                guard let parsed = parseStyle(String(arg.dropFirst(2))) else {
                    Shell.bashCurrent.stderr("nl: invalid body numbering style: "
                                             + "'\(arg.dropFirst(2))'\n")
                    return ExitStatus(2)
                }
                style = parsed; idx += 1; continue
            }
            if arg == "-w" {
                guard idx + 1 < rawArgv.count, let value = Int(rawArgv[idx + 1]) else {
                    Shell.bashCurrent.stderr("nl: -w requires N\n"); return ExitStatus(2)
                }
                width = value; idx += 2; continue
            }
            if arg.hasPrefix("-w") && arg.count > 2, let value = Int(arg.dropFirst(2)) {
                width = value; idx += 1; continue
            }
            if arg == "-s" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("nl: -s requires STR\n"); return ExitStatus(2)
                }
                separator = rawArgv[idx + 1]; idx += 2; continue
            }
            if arg.hasPrefix("-s") && arg.count > 2 {
                separator = String(arg.dropFirst(2)); idx += 1; continue
            }
            if arg == "-v" {
                guard idx + 1 < rawArgv.count, let value = Int(rawArgv[idx + 1]) else {
                    Shell.bashCurrent.stderr("nl: -v requires N\n"); return ExitStatus(2)
                }
                counter = value; idx += 2; continue
            }
            if arg.hasPrefix("-v") && arg.count > 2, let value = Int(arg.dropFirst(2)) {
                counter = value; idx += 1; continue
            }
            if arg.hasPrefix("-") && arg.count > 1 && arg != "-" {
                Shell.bashCurrent.stderr("nl: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            files.append(arg); idx += 1
        }

        func emit(_ line: String) {
            let shouldNumber: Bool = {
                switch style {
                case .all: return true
                case .nonEmpty: return !line.isEmpty
                case .off: return false
                }
            }()
            if shouldNumber {
                let numStr = String(counter)
                let pad = max(0, width - numStr.count)
                Shell.bashCurrent.stdout(String(repeating: " ", count: pad)
                             + numStr + separator + line + "\n")
                counter += 1
            } else {
                Shell.bashCurrent.stdout(line + "\n")
            }
        }

        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for path in inputs {
            if path == "-" {
                for await line in Shell.bashCurrent.stdin.lines { emit(line) }
                continue
            }
            do {
                let data = try await Shell.bashCurrent.readDataAtPath(path)
                // nl input may legitimately be partial UTF-8.
                // swiftlint:disable:next optional_data_string_conversion
                let text = String(decoding: data, as: UTF8.self)
                let parts = text.split(separator: "\n",
                                       omittingEmptySubsequences: false)
                                .map(String.init)
                let lines = (text.hasSuffix("\n") && !parts.isEmpty)
                    ? Array(parts.dropLast())
                    : parts
                for line in lines { emit(line) }
            } catch FileSystemError.notFound {
                Shell.bashCurrent.stderr("nl: \(path): No such file or directory\n")
                hadError = true
            } catch FileSystemError.isADirectory {
                Shell.bashCurrent.stderr("nl: \(path): Is a directory\n")
                hadError = true
            } catch {
                Shell.bashCurrent.stderr("nl: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func parseStyle(_ name: String) -> BodyStyle? {
        switch name {
        case "a": return .all
        case "t": return .nonEmpty
        case "n": return .off
        default: return nil
        }
    }
}
