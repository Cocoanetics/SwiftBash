import ArgumentParser
import BashInterpreter
import Foundation

/// `more [OPTIONS] [FILE...]` — view content one screen at a time
/// (less's older, simpler ancestor).
///
/// Same dispatch pattern as ``LessCommand``:
///
/// - Interactive stdout + presenter installed → request a pager view
///   in ``PagerRequest/Mode/more`` mode. The host advertises only the
///   stripped-down `more` key set (Space, Enter, q).
/// - Non-interactive → pass content through to stdout, matching real
///   `more(1)` when its stdout isn't a TTY.
///
/// Supported flag surface:
/// - `-d` — print prompt messages (always on for our pager view;
///   accepted for compatibility).
/// - `-s` — squeeze multiple blank lines into one.
/// - `-u` — accept-and-ignore (suppresses underline / bold; we don't
///   alter ANSI either way).
/// - `+G` — start at the end.
/// - `+N` — start at line N.
public struct MoreCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "more",
        abstract: "View content one screen at a time."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        let shell = Shell.bashCurrent
        var parsed: ParsedArgs
        switch parseArgs(shell: shell) {
        case .success(let args): parsed = args
        case .failure(let code): return code
        }

        // Collect content.
        let inputs: [String] = parsed.files.isEmpty ? ["-"] : parsed.files
        var (content, hadFileError) = await collectContent(inputs: inputs, shell: shell)

        if parsed.squeeze { content = collapseBlankLines(content) }

        let interactive = shell.stdoutIsTTY && shell.interactivePresenter != nil
        if interactive {
            let title = parsed.files.first(where: { $0 != "-" })
            let request = PagerRequest(
                content: content,
                mode: .more,
                title: title,
                startAtEnd: parsed.startAtEnd,
                lineNumbers: false,
                ignoreCaseInSearch: false,
                chopLongLines: false)
            do {
                try await shell.interactivePresenter!.presentPager(request)
            } catch is CancellationError {
                return ExitStatus(130)
            }
            return hadFileError ? ExitStatus(1) : .success
        }

        shell.stdout(content)
        return hadFileError ? ExitStatus(1) : .success
    }

    /// Read every input into a single string, separated by `more`-style
    /// `::::::::::::::\nFILE\n::::::::::::::` banners when there's more
    /// than one. Returns the joined text and whether any file failed.
    private func collectContent(inputs: [String], shell: Shell) async -> (String, Bool) {
        var content = ""
        var hadFileError = false
        let multi = inputs.count > 1
        for (idx, file) in inputs.enumerated() {
            let chunk: String
            do {
                if file == "-" {
                    chunk = await shell.stdin.readAllString()
                } else {
                    let source = try await shell.openInputPath(file)
                    chunk = await source.readAllString()
                }
            } catch FileSystemError.notFound {
                shell.stderr("more: \(file): No such file or directory\n")
                hadFileError = true
                continue
            } catch {
                shell.stderr("more: \(file): \(error)\n")
                hadFileError = true
                continue
            }
            if multi {
                if idx > 0, !content.hasSuffix("\n") { content += "\n" }
                let label = file == "-" ? "(stdin)" : file
                content += "::::::::::::::\n\(label)\n::::::::::::::\n"
            }
            content += chunk
        }
        return (content, hadFileError)
    }

    private struct ParsedArgs {
        var squeeze: Bool
        var startAtEnd: Bool
        var startAtLine: Int?
        var files: [String]
    }

    private enum ArgResult {
        case success(ParsedArgs)
        case failure(ExitStatus)
    }

    // Argv loop: walks `+N` / `+G` plus bundled short flags. Each char
    // gets a one-line switch case so the option set is the dispatch
    // table; per-flag helpers would just scatter it.
    // swiftlint:disable:next cyclomatic_complexity
    private func parseArgs(shell: Shell) -> ArgResult {
        var squeeze = false
        var startAtEnd = false
        var startAtLine: Int?
        var files: [String] = []
        var index = 0
        var sawDoubleDash = false
        while index < rawArgv.count {
            let arg = rawArgv[index]
            if sawDoubleDash { files.append(arg); index += 1; continue }
            if arg == "--" { sawDoubleDash = true; index += 1; continue }
            if arg == "-" { files.append("-"); index += 1; continue }
            if arg.hasPrefix("+"), arg.count > 1 {
                let rest = String(arg.dropFirst())
                if rest == "G" { startAtEnd = true; index += 1; continue }
                if let lineNo = Int(rest), lineNo >= 1 {
                    startAtLine = lineNo; index += 1; continue
                }
                shell.stderr("more: unrecognized option: \(arg)\n")
                return .failure(ExitStatus(2))
            }
            if arg.hasPrefix("-"), arg.count > 1 {
                for char in arg.dropFirst() {
                    switch char {
                    case "d": break   // prompt is always on in our pager
                    case "s": squeeze = true
                    case "u": break   // underline-suppress — no-op
                    case "p": break   // clear-screen page — no-op
                    case "c": break   // clear-and-overwrite — no-op
                    case "f": break   // count logical lines — no-op
                    default:
                        shell.stderr("more: unrecognized option: -\(char)\n")
                        return .failure(ExitStatus(2))
                    }
                }
                index += 1; continue
            }
            files.append(arg)
            index += 1
        }
        _ = startAtLine // reserved for future +N handling in presenter
        return .success(ParsedArgs(squeeze: squeeze,
                              startAtEnd: startAtEnd,
                              startAtLine: startAtLine,
                              files: files))
    }

    /// `more -s` — collapse runs of two or more newlines into a single
    /// blank line. Matches real `more`'s "squeeze-blank-lines" output.
    private func collapseBlankLines(_ str: String) -> String {
        let parts = str.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var prevBlank = false
        for part in parts {
            if part.isEmpty {
                if prevBlank { continue }
                prevBlank = true
            } else {
                prevBlank = false
            }
            kept.append(part)
        }
        return kept.joined(separator: "\n")
    }
}
