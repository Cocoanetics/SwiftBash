import ArgumentParser
import BashInterpreter
import Foundation

/// `xargs [OPTIONS] [COMMAND [INITIAL-ARGS]]` — build and execute
/// command lines from standard input.
///
/// Default: read items from stdin separated by whitespace, append all
/// of them to COMMAND (defaulting to `echo`), run once.
///
/// - `-n N` — at most N items per command line (one command per N).
/// - `-I REPLACE` — run command once per item, substituting REPLACE
///   in every argument with the item.
/// - `-0` / `--null` — items separated by NUL (matches `find -print0`)
/// - `-d DELIM` — custom delimiter (literal string, with `\n` `\t`
///   `\r` `\0` `\\` escapes recognised)
/// - `-r` / `--no-run-if-empty` — skip the command if input is empty
/// - `-t` / `--verbose` — print each command to stderr before running
/// - `-P N` — accepted; sequential execution only (we don't fork).
public struct XargsCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "xargs",
        abstract: "Build and execute command lines from standard input."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, then COMMAND [INITIAL-ARGS].")
    public var rawArgv: [String] = []

    public init() {}

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var replaceStr: String?
        var delimiter: String?
        var maxArgs: Int?
        var nullSep = false
        var verbose = false
        var noRunIfEmpty = false

        var idx = 0
        var cmdStart = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "-I" || arg == "--replace" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("xargs: -I requires REPLACE\n"); return ExitStatus(2)
                }
                replaceStr = rawArgv[idx + 1]; idx += 2; cmdStart = idx; continue
            }
            if arg.hasPrefix("--replace=") {
                replaceStr = String(arg.dropFirst("--replace=".count)); idx += 1; cmdStart = idx; continue
            }
            if arg == "-d" || arg == "--delimiter" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("xargs: -d requires DELIM\n"); return ExitStatus(2)
                }
                delimiter = unescape(rawArgv[idx + 1]); idx += 2; cmdStart = idx; continue
            }
            if arg == "-n" || arg == "--max-args" {
                guard idx + 1 < rawArgv.count, let num = Int(rawArgv[idx + 1]) else {
                    Shell.bashCurrent.stderr("xargs: -n requires N\n"); return ExitStatus(2)
                }
                maxArgs = num; idx += 2; cmdStart = idx; continue
            }
            if arg == "-P" || arg == "--max-procs" {
                // Accept but ignore; we run sequentially.
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("xargs: -P requires N\n"); return ExitStatus(2)
                }
                idx += 2; cmdStart = idx; continue
            }
            if arg == "-0" || arg == "--null" {
                nullSep = true; idx += 1; cmdStart = idx; continue
            }
            if arg == "-t" || arg == "--verbose" {
                verbose = true; idx += 1; cmdStart = idx; continue
            }
            if arg == "-r" || arg == "--no-run-if-empty" {
                noRunIfEmpty = true; idx += 1; cmdStart = idx; continue
            }
            if arg.hasPrefix("--") {
                Shell.bashCurrent.stderr("xargs: unknown option: \(arg)\n")
                return ExitStatus(2)
            }
            if arg.hasPrefix("-") && arg.count > 1 && arg != "-" {
                // Combined boolean short options (-tr, -0r, etc.)
                for char in arg.dropFirst() {
                    switch char {
                    case "0": nullSep = true
                    case "t": verbose = true
                    case "r": noRunIfEmpty = true
                    default:
                        Shell.bashCurrent.stderr("xargs: unknown option: -\(char)\n")
                        return ExitStatus(2)
                    }
                }
                idx += 1; cmdStart = idx; continue
            }
            cmdStart = idx
            break
        }

        var commandTemplate = Array(rawArgv[cmdStart...])
        if commandTemplate.isEmpty { commandTemplate = ["echo"] }

        // Read stdin and split into items.
        let raw = await Shell.bashCurrent.stdin.readAllString()
        let items: [String]
        if nullSep {
            items = raw.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        } else if let delim = delimiter {
            // Strip a single trailing newline (echo adds one), then split.
            var input = raw
            if input.hasSuffix("\n") { input.removeLast() }
            items = input.components(separatedBy: delim).filter { !$0.isEmpty }
        } else {
            items = raw.split(omittingEmptySubsequences: true,
                              whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        if items.isEmpty {
            return noRunIfEmpty ? .success : .success
        }

        // Build the list of invocations.
        var invocations: [[String]] = []
        if let replace = replaceStr {
            for item in items {
                invocations.append(commandTemplate.map { $0.replacingOccurrences(of: replace, with: item) })
            }
        } else if let chunk = maxArgs, chunk > 0 {
            var batchIdx = 0
            while batchIdx < items.count {
                let batch = Array(items[batchIdx..<min(batchIdx + chunk, items.count)])
                invocations.append(commandTemplate + batch)
                batchIdx += chunk
            }
        } else {
            invocations.append(commandTemplate + items)
        }

        var lastStatus: ExitStatus = .success
        for argv in invocations {
            // `xargs -n1 huge-list cmd` runs N invocations; honour
            // cancellation between them so kill -TERM lands.
            try Task.checkCancellation()
            let line = argv.map(shellQuote).joined(separator: " ")
            if verbose { Shell.bashCurrent.stderr(line + "\n") }
            do {
                lastStatus = try await Shell.bashCurrent.run(line)
            } catch {
                Shell.bashCurrent.stderr("xargs: \(error)\n")
                return .failure
            }
        }
        return lastStatus
    }

    private func unescape(_ str: String) -> String {
        str.replacingOccurrences(of: "\\\\", with: "\u{0001}")
           .replacingOccurrences(of: "\\n", with: "\n")
           .replacingOccurrences(of: "\\t", with: "\t")
           .replacingOccurrences(of: "\\r", with: "\r")
           .replacingOccurrences(of: "\\0", with: "\0")
           .replacingOccurrences(of: "\u{0001}", with: "\\")
    }

    private func shellQuote(_ str: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !str.isEmpty && str.allSatisfy({ safe.contains($0) }) { return str }
        return "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
