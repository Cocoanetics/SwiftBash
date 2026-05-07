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

    public mutating func execute() async throws -> ExitStatus {
        var replaceStr: String? = nil
        var delimiter: String? = nil
        var maxArgs: Int? = nil
        var nullSep = false
        var verbose = false
        var noRunIfEmpty = false

        var i = 0
        var cmdStart = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-I" || a == "--replace" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("xargs: -I requires REPLACE\n"); return ExitStatus(2)
                }
                replaceStr = rawArgv[i + 1]; i += 2; cmdStart = i; continue
            }
            if a.hasPrefix("--replace=") {
                replaceStr = String(a.dropFirst("--replace=".count)); i += 1; cmdStart = i; continue
            }
            if a == "-d" || a == "--delimiter" {
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("xargs: -d requires DELIM\n"); return ExitStatus(2)
                }
                delimiter = unescape(rawArgv[i + 1]); i += 2; cmdStart = i; continue
            }
            if a == "-n" || a == "--max-args" {
                guard i + 1 < rawArgv.count, let n = Int(rawArgv[i + 1]) else {
                    Shell.bashCurrent.stderr("xargs: -n requires N\n"); return ExitStatus(2)
                }
                maxArgs = n; i += 2; cmdStart = i; continue
            }
            if a == "-P" || a == "--max-procs" {
                // Accept but ignore; we run sequentially.
                guard i + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("xargs: -P requires N\n"); return ExitStatus(2)
                }
                i += 2; cmdStart = i; continue
            }
            if a == "-0" || a == "--null" {
                nullSep = true; i += 1; cmdStart = i; continue
            }
            if a == "-t" || a == "--verbose" {
                verbose = true; i += 1; cmdStart = i; continue
            }
            if a == "-r" || a == "--no-run-if-empty" {
                noRunIfEmpty = true; i += 1; cmdStart = i; continue
            }
            if a.hasPrefix("--") {
                Shell.bashCurrent.stderr("xargs: unknown option: \(a)\n")
                return ExitStatus(2)
            }
            if a.hasPrefix("-") && a.count > 1 && a != "-" {
                // Combined boolean short options (-tr, -0r, etc.)
                for c in a.dropFirst() {
                    switch c {
                    case "0": nullSep = true
                    case "t": verbose = true
                    case "r": noRunIfEmpty = true
                    default:
                        Shell.bashCurrent.stderr("xargs: unknown option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; cmdStart = i; continue
            }
            cmdStart = i
            break
        }

        var commandTemplate = Array(rawArgv[cmdStart...])
        if commandTemplate.isEmpty { commandTemplate = ["echo"] }

        // Read stdin and split into items.
        let raw = await Shell.bashCurrent.stdin.readAllString()
        let items: [String]
        if nullSep {
            items = raw.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        } else if let d = delimiter {
            // Strip a single trailing newline (echo adds one), then split.
            var input = raw
            if input.hasSuffix("\n") { input.removeLast() }
            items = input.components(separatedBy: d).filter { !$0.isEmpty }
        } else {
            items = raw.split(omittingEmptySubsequences: true,
                              whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        if items.isEmpty {
            return noRunIfEmpty ? .success : .success
        }

        // Build the list of invocations.
        var invocations: [[String]] = []
        if let r = replaceStr {
            for item in items {
                invocations.append(commandTemplate.map { $0.replacingOccurrences(of: r, with: item) })
            }
        } else if let n = maxArgs, n > 0 {
            var idx = 0
            while idx < items.count {
                let batch = Array(items[idx..<min(idx + n, items.count)])
                invocations.append(commandTemplate + batch)
                idx += n
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

    private func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\\", with: "\u{0001}")
         .replacingOccurrences(of: "\\n", with: "\n")
         .replacingOccurrences(of: "\\t", with: "\t")
         .replacingOccurrences(of: "\\r", with: "\r")
         .replacingOccurrences(of: "\\0", with: "\0")
         .replacingOccurrences(of: "\u{0001}", with: "\\")
    }

    private func shellQuote(_ s: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !s.isEmpty && s.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
