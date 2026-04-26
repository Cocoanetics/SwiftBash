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

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        var style: BodyStyle = .nonEmpty
        var width = 6
        var separator = "\t"
        var counter = 1
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
            if a == "-b" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("nl: -b requires TYPE\n"); return ExitStatus(2)
                }
                guard let s = parseStyle(rawArgv[i + 1]) else {
                    shell.stderr("nl: invalid body numbering style: '\(rawArgv[i + 1])'\n")
                    return ExitStatus(2)
                }
                style = s; i += 2; continue
            }
            if a.hasPrefix("-b") && a.count > 2 {
                guard let s = parseStyle(String(a.dropFirst(2))) else {
                    shell.stderr("nl: invalid body numbering style: '\(a.dropFirst(2))'\n")
                    return ExitStatus(2)
                }
                style = s; i += 1; continue
            }
            if a == "-w" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]) else {
                    shell.stderr("nl: -w requires N\n"); return ExitStatus(2)
                }
                width = n; i += 2; continue
            }
            if a.hasPrefix("-w") && a.count > 2, let n = Int(a.dropFirst(2)) {
                width = n; i += 1; continue
            }
            if a == "-s" {
                guard i + 1 < rawArgv.count else {
                    shell.stderr("nl: -s requires STR\n"); return ExitStatus(2)
                }
                separator = rawArgv[i + 1]; i += 2; continue
            }
            if a.hasPrefix("-s") && a.count > 2 {
                separator = String(a.dropFirst(2)); i += 1; continue
            }
            if a == "-v" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]) else {
                    shell.stderr("nl: -v requires N\n"); return ExitStatus(2)
                }
                counter = n; i += 2; continue
            }
            if a.hasPrefix("-v") && a.count > 2, let n = Int(a.dropFirst(2)) {
                counter = n; i += 1; continue
            }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                shell.stderr("nl: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            files.append(a); i += 1
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
                shell.stdout(String(repeating: " ", count: pad)
                             + numStr + separator + line + "\n")
                counter += 1
            } else {
                shell.stdout(line + "\n")
            }
        }

        let inputs = files.isEmpty ? ["-"] : files
        var hadError = false
        for path in inputs {
            if path == "-" {
                for await line in shell.stdin.lines { emit(line) }
                continue
            }
            do {
                let data = try await shell.readDataAtPath(path)
                let text = String(decoding: data, as: UTF8.self)
                let parts = text.split(separator: "\n",
                                       omittingEmptySubsequences: false)
                                .map(String.init)
                let lines = (text.hasSuffix("\n") && !parts.isEmpty)
                    ? Array(parts.dropLast())
                    : parts
                for line in lines { emit(line) }
            } catch FileSystemError.notFound {
                shell.stderr("nl: \(path): No such file or directory\n")
                hadError = true
            } catch FileSystemError.isADirectory {
                shell.stderr("nl: \(path): Is a directory\n")
                hadError = true
            } catch {
                shell.stderr("nl: \(path): \(error)\n")
                hadError = true
            }
        }
        return hadError ? .failure : .success
    }

    private func parseStyle(_ s: String) -> BodyStyle? {
        switch s {
        case "a": return .all
        case "t": return .nonEmpty
        case "n": return .off
        default: return nil
        }
    }
}
