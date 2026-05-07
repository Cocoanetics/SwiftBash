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

    public func run(_ argv: [String]) async throws -> ExitStatus {
        let args = Array(argv.dropFirst())

        // bash --version
        if args.first == "--version" {
            Shell.bashCurrent.stdout(SwiftBashVersion.banner + "\n")
            return .success
        }
        // bash --help
        if args.first == "--help" {
            Shell.bashCurrent.stdout(Self.helpText(name: name))
            return .success
        }

        // bash -c CMD [name [arg1 …]]
        if args.first == "-c" {
            guard args.count >= 2 else {
                Shell.bashCurrent.stderr(
                    "\(name): -c: option requires an argument\n")
                return ExitStatus(2)
            }
            let source = args[1]
            let scriptName = args.count >= 3 ? args[2] : name
            let scriptArgs = Array(args.dropFirst(3))
            return try await runScript(
                source: source, scriptName: scriptName, args: scriptArgs)
        }

        // No args — read from stdin.
        if args.isEmpty {
            let data = await drainStdin()
            if data.isEmpty { return .success }
            let source = String(decoding: data, as: UTF8.self)
            return try await runScript(
                source: source, scriptName: name, args: [])
        }

        // bash FILE [args…]
        let path = args[0]
        let scriptArgs = Array(args.dropFirst())
        let resolved = Shell.bashCurrent.resolvePath(path)
        let data: Data
        do {
            data = try await Shell.bashCurrent.fileSystem.readData(resolved)
        } catch {
            Shell.bashCurrent.stderr(
                "\(name): \(path): No such file or directory\n")
            return ExitStatus(127)
        }
        let source = String(decoding: data, as: UTF8.self)
        return try await runScript(
            source: source, scriptName: path, args: scriptArgs)
    }

    // MARK: Script execution

    /// Run `source` in a fresh subshell with the given `$0` and
    /// positional parameters. Strips a leading `#!shebang` line so
    /// script files don't choke the parser.
    private func runScript(source: String,
                           scriptName: String,
                           args: [String]) async throws -> ExitStatus
    {
        var src = source
        if src.hasPrefix("#!"), let nl = src.firstIndex(of: "\n") {
            src = String(src[src.index(after: nl)...])
        }
        let sub = Shell.bashCurrent.copy()
        sub.scriptName = scriptName
        sub.positionalParameters = args
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
