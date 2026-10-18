import Foundation
import BashSyntax

/// `bash` / `sh` / `dash` — re-enter the interpreter on a script
/// string, file, or stdin.
///
/// Supports the four common invocations:
/// - `bash --version`      — print version banner, exit 0.
/// - `bash --help`         — print usage, exit 0.
/// - `bash -c CMD [name [arg1 …]]`
///                          — run CMD as a script. `$0 = name`
///                            (default `"bash"` / `"sh"` / `"dash"`),
///                            `$1+ = arg1 …`.
/// - `bash FILE [args…]`   — read FILE and run it. `$0 = FILE`,
///                            `$1+ = args…`. Missing file → exit 127.
/// - `bash` (no args)       — drain stdin and run it. Empty stdin →
///                            exit 0 (we have no interactive REPL).
///
/// Each form runs in a fresh ``Shell/copy()`` — bash subshell
/// semantics. Mutations to env, cwd, options don't leak back to
/// the parent shell.
///
/// A leading `#!shebang` line is stripped before parsing so script
/// files saved with `#!/usr/bin/env bash` don't confuse the parser.
///
/// Why this matters: many scripts probe `bash --version`,
/// `$BASH_VERSION`, or invoke helper scripts via `bash subscript.sh`.
/// Without this command, those scripts fail with `command not
/// found`. With it, SwiftBash advertises its 4.x-target identity and
/// transparently re-enters itself for nested scripts.
public struct BashCommand: Command {
    public let name: String
    public init(name: String = "bash") { self.name = name }

    // Argv parsing for bash invocations is inherently switch-heavy
    // (per-character short-flag bundle, plus --foo long flags). Splitting
    // it further would just create plumbing for no readability win.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())

        // Parse options. Real bash accepts `--version` / `--help`
        // anywhere in argv (not just position 0), `-c CMD …` to run
        // a literal command string, and a small set of mode flags
        // (`-n -e -u -x -v -f -C`) that apply to the subshell before its
        // run loop starts. Anything else is the positional script
        // path. The single loop here keeps `bash -e -c 'echo hi'` /
        // `bash -ex script.sh` working uniformly.
        var parseOnly = false
        var modeFlags = SubshellModeFlags()
        var sawDoubleDash = false
        var commandString = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            if sawDoubleDash { break }
            if arg == "--" { sawDoubleDash = true; index += 1; break }
            // Long options come before the short ones: bash rejects
            // `bash -c --help`.
            if commandString, arg.hasPrefix("--") {
                Shell.bashCurrent.stderr("\(name): --: invalid option\n")
                return ExitStatus(2)
            }
            if arg == "--version" {
                Shell.bashCurrent.stdout(SwiftBashVersion.banner + "\n")
                return .success
            }
            if arg == "--help" {
                Shell.bashCurrent.stdout(Self.helpText(name: name))
                return .success
            }
            if !arg.hasPrefix("-") || arg.count <= 1 {
                // First positional — script path.
                break
            }
            // Short-flag bundle. Characters accumulate into mode flags;
            // `-c` only says the first argument after the options is a
            // command string. We walk character-by-character so combos
            // like `-eux` and `-cf` work.
            for char in arg.dropFirst() {
                switch char {
                case "n": parseOnly = true
                case "e": modeFlags.errexit = true
                case "u": modeFlags.nounset = true
                case "x": modeFlags.xtrace = true
                case "v": modeFlags.verbose = true
                case "f": modeFlags.noglob = true
                case "C": modeFlags.noclobber = true
                case "l", "i", "s":
                    // -l (login shell): we always source `.profile` on
                    // interpreter init, so the login-shell side effect
                    // is already in place.
                    // -i (force interactive): we're always interactive.
                    // -s (read commands from stdin): the default when no
                    // script path is given, which is what the loop
                    // below already does.
                    // Accept all three as no-ops so combos like
                    // `bash -lc 'cmd'` work — the agent's bug report
                    // called out `bash -lc` specifically.
                    break
                case "c":
                    // As in bash, `-c` can sit anywhere among the
                    // options (`-ec`, `-cf`, `-c -e`).
                    commandString = true
                default:
                    Shell.bashCurrent.stderr(
                        "\(name): -\(char): invalid option\n")
                    return ExitStatus(2)
                }
            }
            index += 1
        }

        let positional = Array(args[index...])
        // -c form short-circuits — runs the first argument as the
        // script source, no file read. The next one is `$0`, the rest
        // are positionals.
        if commandString {
            guard let source = positional.first else {
                Shell.bashCurrent.stderr(
                    "\(name): -c: option requires an argument\n")
                return ExitStatus(2)
            }
            return try await runScript(
                source: source,
                scriptName: positional.count > 1 ? positional[1] : name,
                args: Array(positional.dropFirst(2)),
                mode: modeFlags,
                commandString: true)
        }
        guard let path = positional.first else {
            // `bash -n` / `bash -x` with no file: real bash drops to
            // its interactive REPL. We have none, so drain stdin.
            let data = await drainStdin()
            if data.isEmpty { return .success }
            // Script bytes may include non-UTF8 in heredocs/comments;
            // lossy decode is the standard bash behavior.
            // swiftlint:disable:next optional_data_string_conversion
            let source = String(decoding: data, as: UTF8.self)
            if parseOnly { return try parseCheck(source: source) }
            return try await runScript(
                source: source, scriptName: name, args: [], mode: modeFlags)
        }
        let scriptArgs = Array(positional.dropFirst())
        let data: Data
        do {
            // `readDataAtPath` honors the `/dev/{stdin,null,stdout,
            // stderr}` magic-path table on top of the filesystem, so
            // `bash /dev/stdin` reads our shell's stdin instead of
            // failing with ENOENT.
            data = try await Shell.bashCurrent.readDataAtPath(path)
        } catch {
            Shell.bashCurrent.stderr(
                "\(name): \(path): No such file or directory\n")
            return ExitStatus(127)
        }
        // Same rationale as the stdin path above — accept lossy decode.
        // swiftlint:disable:next optional_data_string_conversion
        let source = String(decoding: data, as: UTF8.self)
        if parseOnly { return try parseCheck(source: source) }
        return try await runScript(
            source: source, scriptName: path, args: scriptArgs,
            mode: modeFlags, scriptFile: path)
    }

    /// Mode flags parsed from `bash`'s argv that need to be applied
    /// to the subshell before its run loop starts. Kept as a value
    /// type so the two call sites (file + stdin) hand the same shape
    /// to ``runScript``.
    private struct SubshellModeFlags {
        var errexit: Bool = false
        var nounset: Bool = false
        var xtrace: Bool = false
        var verbose: Bool = false
        var noglob: Bool = false
        var noclobber: Bool = false
    }

    /// `bash -n` — parse `source` and report any syntax error to
    /// stderr without executing. Strips a leading shebang the way
    /// `runScript` does so a `#!/usr/bin/env bash` doesn't trip the
    /// parser.
    private func parseCheck(source: String) throws -> ExitStatus {
        var src = source
        if src.hasPrefix("#!"), let newline = src.firstIndex(of: "\n") {
            // Keep the newline, so `$LINENO` and diagnostics count the
            // shebang's line.
            src = String(src[newline...])
        }
        do {
            _ = try BashSyntax.parse(src)
            return .success
        } catch {
            Shell.bashCurrent.stderr("\(name): \(error)\n")
            return ExitStatus(2)
        }
    }

    // MARK: Script execution

    /// Run `source` in a fresh subshell with the given `$0` and
    /// positional parameters. Strips a leading `#!shebang` line so
    /// script files don't choke the parser. `mode` carries the
    /// `bash -euxv` flags parsed from argv — they layer onto the
    /// copied shell BEFORE the run loop starts so they affect every
    /// command in the script, including the first one.
    /// `commandString` marks a `bash -c` string, which `$-` shows.
    private func runScript(source: String,
                           scriptName: String,
                           args: [String],
                           mode: SubshellModeFlags,
                           scriptFile: String? = nil,
                           commandString: Bool = false) async throws -> ExitStatus {
        var src = source
        if src.hasPrefix("#!"), let newline = src.firstIndex(of: "\n") {
            // Keep the newline, so `$LINENO` and diagnostics count the
            // shebang's line.
            src = String(src[newline...])
        }
        let sub = Shell.bashCurrent.childProcess()
        sub.scriptName = scriptName
        sub.scriptFile = scriptFile
        sub.dynamicVariables.commandString = commandString
        sub.positionalParameters = args
        if mode.errexit { sub.errexit = true }
        if mode.nounset { sub.nounset = true }
        if mode.xtrace { sub.xtrace = true }
        if mode.verbose { sub.verbose = true }
        if mode.noglob { sub.noglob = true }
        if mode.noclobber { sub.noclobber = true }
        // Once we hand control to the sub-shell, its stdin is
        // whatever the parent had; we already inherited that
        // through `copy()`. `exit N` inside the script unwinds at
        // the sub-shell's `run()` boundary (it catches `ShellExit`
        // internally), so the call returns the exit status without
        // tearing down our shell — exactly the bash subshell rule.
        return try await sub.run(src)
    }

    /// Drain everything currently buffered on stdin. Used for the
    /// no-args form (`cat file.sh | bash`).
    private func drainStdin() async -> Data {
        var data = Data()
        for await chunk in Shell.bashCurrent.stdin.bytes {
            data.append(chunk)
        }
        return data
    }

    // MARK: Help

    private static func helpText(name: String) -> String {
        """
        Usage: \(name) [OPTIONS] [SCRIPT_FILE [ARGUMENTS...]]
               \(name) -c COMMAND [NAME [ARG...]]

        Options:
          -c COMMAND       Execute COMMAND string.
              --version    Print version information and exit.
              --help       Print this help and exit.

        Without -c, reads and executes commands from SCRIPT_FILE (or
        stdin if no SCRIPT_FILE is given). Arguments are passed as
        $1, $2, … to the script.

        With -c, the optional NAME after COMMAND is set as $0 (default
        "\(name)"); subsequent ARGs become $1, $2, …

        """
    }
}
