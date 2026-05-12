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

        var squeeze = false
        var startAtEnd = false
        var startAtLine: Int? = nil
        var files: [String] = []
        var i = 0
        var sawDoubleDash = false
        while i < rawArgv.count {
            let a = rawArgv[i]
            if sawDoubleDash { files.append(a); i += 1; continue }
            if a == "--" { sawDoubleDash = true; i += 1; continue }
            if a == "-" { files.append("-"); i += 1; continue }
            if a.hasPrefix("+"), a.count > 1 {
                let rest = String(a.dropFirst())
                if rest == "G" { startAtEnd = true; i += 1; continue }
                if let n = Int(rest), n >= 1 {
                    startAtLine = n; i += 1; continue
                }
                shell.stderr("more: unrecognized option: \(a)\n")
                return ExitStatus(2)
            }
            if a.hasPrefix("-"), a.count > 1 {
                for c in a.dropFirst() {
                    switch c {
                    case "d": break   // prompt is always on in our pager
                    case "s": squeeze = true
                    case "u": break   // underline-suppress — no-op
                    case "p": break   // clear-screen page — no-op
                    case "c": break   // clear-and-overwrite — no-op
                    case "f": break   // count logical lines — no-op
                    default:
                        shell.stderr("more: unrecognized option: -\(c)\n")
                        return ExitStatus(2)
                    }
                }
                i += 1; continue
            }
            files.append(a)
            i += 1
        }
        _ = startAtLine // reserved for future +N handling in presenter

        // Collect content.
        let inputs: [String] = files.isEmpty ? ["-"] : files
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

        if squeeze { content = collapseBlankLines(content) }

        let interactive = shell.stdoutIsTTY && shell.interactivePresenter != nil
        if interactive {
            let title = files.first(where: { $0 != "-" })
            let request = PagerRequest(
                content: content,
                mode: .more,
                title: title,
                startAtEnd: startAtEnd,
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

    /// `more -s` — collapse runs of two or more newlines into a single
    /// blank line. Matches real `more`'s "squeeze-blank-lines" output.
    private func collapseBlankLines(_ s: String) -> String {
        let parts = s.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var prevBlank = false
        for p in parts {
            if p.isEmpty {
                if prevBlank { continue }
                prevBlank = true
            } else {
                prevBlank = false
            }
            kept.append(p)
        }
        return kept.joined(separator: "\n")
    }
}
