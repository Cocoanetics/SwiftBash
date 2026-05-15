import ArgumentParser
import BashInterpreter
import Foundation

/// `less [OPTIONS] [FILE...]` — view content one screen at a time.
///
/// Mirrors the subset of `less(1)` that translates to a host-driven
/// interactive view rather than a real TTY:
///
/// - When the shell's `stdout` is interactive (``Shell/stdoutIsTTY``)
///   and an ``InteractivePresenter`` is installed, hands the buffered
///   content to the presenter and waits for the user to dismiss it.
/// - Otherwise — piped, captured, or no host UI — passes content
///   through to stdout, the same way real `less(1)` behaves when
///   `isatty(STDOUT_FILENO)` is `0`. That makes `git log | less | cat`
///   behave like `git log | cat`, which matches bash.
///
/// Supported flag surface (real `less` has many more; this is the set
/// that affects what gets rendered, not the in-pager UX):
/// - `-N` / `--LINE-NUMBERS` — show line numbers.
/// - `-i` / `--ignore-case` — case-insensitive search.
/// - `-S` / `--chop-long-lines` — truncate long lines (default: wrap).
/// - `-F` / `--quit-if-one-screen` — skip the pager when content fits
///   in one screen (size taken from `$LINES`, fallback 24). This is on
///   by default when `git` invokes `less` with `LESS=FRX`.
/// - `-R` / `--RAW-CONTROL-CHARS` — pass ANSI through (always on for
///   us; accepted for compatibility).
/// - `-X` / `--no-init` — no terminal-init sequences (no-op for us).
/// - `+G` — start scrolled to the end (tail-view).
/// - `+N` — start at line N.
/// - `--` — end of options.
///
/// The `LESS` environment variable, if set, is parsed as a leading
/// shorthand prefix (`LESS=FRX` ⇒ `-FRX`) before the explicit argv.
/// Real `less` does the same.
public struct LessCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "less",
        abstract: "View content one screen at a time."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    // `less` execution dispatches across env-var parsing, multi-file
    // joining, $LINES heuristics, and interactive vs non-interactive
    // mode; one branch per case keeps the flow explicit.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        let shell = Shell.bashCurrent

        // Parse `$LESS` first (real less precedence), then the
        // user-supplied argv overrides.
        let envArgv = parseLessEnv(shell.environment["LESS"])
        var opts = LessOptions()
        var parseErr: String?
        if !opts.consume(envArgv, source: "LESS") {
            parseErr = "less: bad option in LESS env var\n"
        }
        if parseErr == nil, !opts.consume(rawArgv, source: "argv") {
            parseErr = "less: \(opts.usageError ?? "bad option")\n"
        }
        if let parseErr {
            shell.stderr(parseErr)
            return ExitStatus(2)
        }
        if opts.showHelp {
            shell.stdout(Self.helpText)
            return .success
        }

        // Collect content from file args (or stdin if none).
        let inputs: [String] = opts.files.isEmpty ? ["-"] : opts.files
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
                shell.stderr("less: \(file): No such file or directory\n")
                hadFileError = true
                continue
            } catch {
                shell.stderr("less: \(file): \(error)\n")
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

        // No files, no stdin payload, host UI present, interactive
        // stdout — real `less` errors out with "Missing filename" here
        // because it has nothing to show and no way to ask for one.
        let interactive = shell.stdoutIsTTY && shell.interactivePresenter != nil
        if interactive, opts.files.isEmpty, content.isEmpty, !hadFileError {
            shell.stderr("less: missing filename (\"less --help\" for help)\n")
            return ExitStatus(1)
        }

        if interactive {
            // `-F`: if content fits in one screen, dump and exit. Size
            // from $LINES; fallback to 24 (the historical default real
            // less uses when termcap can't answer).
            if opts.quitIfOneScreen {
                let rows = Int(shell.environment["LINES"] ?? "") ?? 24
                let lineCount = content.isEmpty
                    ? 0
                    : content.split(
                        separator: "\n",
                        omittingEmptySubsequences: false).count
                if lineCount <= max(1, rows - 1) {
                    shell.stdout(content)
                    return hadFileError ? ExitStatus(1) : .success
                }
            }

            let title: String? = {
                let named = opts.files.filter { $0 != "-" }
                if named.count == 1 { return named[0] }
                if named.isEmpty && !opts.files.isEmpty { return nil }
                return nil
            }()

            let request = PagerRequest(
                content: content,
                mode: .less,
                title: title,
                startAtEnd: opts.startAtEnd,
                lineNumbers: opts.lineNumbers,
                ignoreCaseInSearch: opts.ignoreCase,
                chopLongLines: opts.chopLongLines)
            do {
                try await shell.interactivePresenter!.presentPager(request)
            } catch is CancellationError {
                // Ctrl+C while paging — real less exits with the
                // signal status (128 + SIGINT = 130). Match that.
                return ExitStatus(130)
            }
            return hadFileError ? ExitStatus(1) : .success
        }

        // Non-interactive: cat the buffered content to stdout.
        shell.stdout(content)
        return hadFileError ? ExitStatus(1) : .success
    }

    /// Parse the `LESS` environment variable. A bare token like `FRX`
    /// is treated as `-FRX` (real less convention). Tokens already
    /// carrying `-` or `+` pass through as-is. Whitespace separates
    /// tokens.
    private func parseLessEnv(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .split(whereSeparator: { $0.isWhitespace })
            .map { tok -> String in
                let text = String(tok)
                if text.hasPrefix("-") || text.hasPrefix("+") { return text }
                return "-" + text
            }
    }

    private static let helpText = """
        Usage: less [OPTIONS] [FILE...]
          -N  --LINE-NUMBERS         show line numbers
          -i  --ignore-case          case-insensitive search
          -S  --chop-long-lines      truncate long lines (default: wrap)
          -F  --quit-if-one-screen   skip pager when content fits
          -R  --RAW-CONTROL-CHARS    pass ANSI through (always on)
          -X  --no-init              no terminal init (no-op)
          +G                         start at end of buffer
          +N                         start at line N
          -?  --help                 this message

        """
}

/// Parsed `less` flag/positional split.
struct LessOptions {
    var lineNumbers: Bool = false
    var ignoreCase: Bool = false
    var chopLongLines: Bool = false
    var quitIfOneScreen: Bool = false
    var startAtEnd: Bool = false
    /// `+N` — 1-based starting line. `nil` means "start at top".
    var startAtLine: Int?
    var showHelp: Bool = false
    var files: [String] = []
    var usageError: String?

    // Consume one batch of argv (either from `$LESS` or from the
    // command line). Returns `false` on a parse error and stashes a
    // message in ``usageError``. less consumes a full POSIX option
    // table (short, combined, `+G`, `+N`, long forms, double-dash);
    // per-case-branch dispatch keeps the option matrix readable.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    mutating func consume(_ argv: [String], source: String) -> Bool {
        var idx = 0
        var sawDoubleDash = false
        while idx < argv.count {
            let arg = argv[idx]
            if sawDoubleDash {
                files.append(arg); idx += 1; continue
            }
            if arg == "--" {
                sawDoubleDash = true; idx += 1; continue
            }
            if arg == "-" { files.append("-"); idx += 1; continue }
            // `+G` and `+N` — less's "start at" shorthand.
            if arg.hasPrefix("+"), arg.count > 1 {
                let rest = String(arg.dropFirst())
                if rest == "G" {
                    startAtEnd = true; idx += 1; continue
                }
                if let value = Int(rest), value >= 1 {
                    startAtLine = value; idx += 1; continue
                }
                usageError = "unrecognized option: \(arg)"
                return false
            }
            if arg.hasPrefix("--") {
                switch arg {
                case "--LINE-NUMBERS":      lineNumbers = true
                case "--ignore-case":       ignoreCase = true
                case "--chop-long-lines":   chopLongLines = true
                case "--quit-if-one-screen": quitIfOneScreen = true
                case "--RAW-CONTROL-CHARS", "--raw-control-chars":
                    break // accept; ANSI is always raw in our renderer
                case "--no-init":
                    break // accept; we have no termcap init to skip
                case "--help":              showHelp = true
                default:
                    usageError = "unrecognized option: \(arg)"
                    return false
                }
                idx += 1; continue
            }
            if arg.hasPrefix("-"), arg.count > 1 {
                for flagChar in arg.dropFirst() {
                    switch flagChar {
                    case "N": lineNumbers = true
                    case "i": ignoreCase = true
                    case "S": chopLongLines = true
                    case "F": quitIfOneScreen = true
                    case "R", "r": break // raw ANSI; always-on
                    case "X": break       // no-init; no-op
                    case "?": showHelp = true
                    default:
                        usageError = "unrecognized option: -\(flagChar)"
                        return false
                    }
                }
                idx += 1; continue
            }
            files.append(arg)
            idx += 1
        }
        _ = source // reserved for future "in $LESS" diagnostics
        return true
    }
}
