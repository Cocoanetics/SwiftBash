import Foundation
import BashSyntax

/// A minimal bash interpreter operating on ASTs from ``BashSyntax``.
///
/// The shell holds an ``Environment``, a registry of commands, and a
/// triple of byte-oriented stdio — `stdin` as an ``InputSource`` and
/// `stdout` / `stderr` as `Data` sinks. Convenience overloads accept
/// `String`, UTF-8-encoding automatically, so text-oriented commands
/// stay readable.
///
/// ```swift
/// let shell = Shell()
/// shell.environment["PATH"] = "/usr/bin:/bin"
/// try await shell.run("echo $PATH")
/// ```
///
/// The interpreter is fully async: every `run` is an `await`, and
/// pipeline stages execute concurrently via Swift `Task`s so
/// streaming pipelines (`tail -f file | grep error`) work without
/// buffering the entire upstream output.
public final class Shell: @unchecked Sendable {

    /// The shell's mutable environment (variables + cwd).
    public var environment: Environment

    /// Byte-oriented stdout. Defaults to forwarding to fd 1. Replace
    /// with `OutputSink()` to capture, or iterate `stdout.bytes` /
    /// `stdout.lines` to consume live.
    public var stdout: OutputSink

    /// Byte-oriented stderr. Defaults to forwarding to fd 2.
    public var stderr: OutputSink

    /// Standard input made available to commands. Empty by default;
    /// the pipeline executor swaps this out per stage. Tests can set
    /// it directly to feed a single command.
    public var stdin: InputSource = .empty

    /// Commands keyed by name.
    public var commands: [String: Command]

    /// The filesystem the shell reads and writes through. Defaults to
    /// ``RealFileSystem`` (the host's real `FileManager`). Swap in
    /// `InMemoryFileSystem` or similar to sandbox scripts.
    public var fileSystem: FileSystem

    /// Positional parameters — `$1` is `positionalParameters[0]`, etc.
    /// Set this directly, or use `set -- a b c` from a script. The
    /// CLI's `swift-bash exec script.sh arg1 arg2` populates them.
    public var positionalParameters: [String] = []

    /// `$0` — the script or shell name. Defaults to "swift-bash".
    public var scriptName: String = "swift-bash"

    /// Exit status of the most recently completed command.
    public internal(set) var lastExitStatus: ExitStatus = .success

    /// `set -e` / `set -o errexit` — when `true`, the shell exits as
    /// soon as a command returns a non-zero status, except inside a
    /// "checked" context tracked via ``errexitGuard``.
    public var errexit: Bool = false

    /// `set -o pipefail` — when `true`, a pipeline's exit status is
    /// the rightmost non-zero stage (or 0 if all succeeded), instead
    /// of just the last stage.
    public var pipefail: Bool = false

    /// `set -u` / `set -o nounset` — when `true`, expanding an unset
    /// parameter is an error rather than silently producing "".
    /// Reserved for future implementation; currently unused.
    public var nounset: Bool = false

    /// Counter tracking nested "checked" contexts in which `errexit`
    /// is suppressed (`if`/`while`/`until` conditions, LHS of
    /// `&&`/`||`). `errexit` only triggers when this is 0.
    var errexitGuard: Int = 0

    /// Set by an executed `!`-pipeline to tell the enclosing list
    /// loop to skip its post-command `errexit` check (bash exempts
    /// `!`-inverted commands from errexit). Consumed on the next
    /// executeList iteration.
    var skipNextErrexitCheck: Bool = false

    /// Trap handlers keyed by canonical signal name. Special pseudo-
    /// signals supported: `EXIT` (run when `run()` returns), `ERR`
    /// (run after each command that fails), `DEBUG` (run before each
    /// simple command), `RETURN` (run when a function returns). Real
    /// process signals (`INT`, `TERM`, …) are accepted by `trap` and
    /// stored, but without OS signal delivery they only matter for
    /// `trap -p` introspection.
    var traps: [String: String] = [:]

    /// Re-entrancy guard so a trap handler can't recursively fire its
    /// own type while running.
    var runningTraps: Set<String> = []

    /// Cursor-within-current-argument used by ``getopts`` to track
    /// `-abc`-style bundled short options between calls. Reset to 1
    /// (just past the leading `-`) whenever `getopts` advances OPTIND.
    var getoptsCharIndex: Int = 1

    /// Depth of enclosing `while`/`until`/`for` loops on the call stack.
    /// See `LoopControlSignal` for why this matters.
    var loopDepth: Int = 0

    /// Depth of nested function calls on the call stack. Used by
    /// `local` (only valid `> 0`) and `return` (only meaningful `> 0`).
    var functionCallDepth: Int = 0

    /// Stack of function-local variable frames. The top frame is
    /// the currently-running function's locals; each entry records
    /// the variable's *previous* value so it can be restored on
    /// function return.
    var localVarStack: [[(name: String, prior: String?)]] = []

    /// Process substitutions allocated during expansion that need
    /// post-command cleanup (delete the temp file, and for `>(cmd)`
    /// run the consumer with the captured bytes as stdin).
    var pendingProcessSubs: [ProcessSub] = []

    /// One pending `<(cmd)` or `>(cmd)` substitution.
    struct ProcessSub: Sendable {
        enum Kind: Sendable { case input, output }
        let kind: Kind
        let path: String
        let consumer: Node?  // for `.output`, the command to feed
    }

    public init(environment: Environment = Environment(),
                stdout: OutputSink? = nil,
                stderr: OutputSink? = nil,
                commands: [String: Command] = Shell.defaultCommands(),
                fileSystem: FileSystem = RealFileSystem())
    {
        self.environment = environment
        self.stdout = stdout ?? .forwarding(to: FileHandle.standardOutput)
        self.stderr = stderr ?? .forwarding(to: FileHandle.standardError)
        self.commands = commands
        self.fileSystem = fileSystem
    }

    // MARK: Default registry

    public static func defaultCommands() -> [String: Command] {
        let all: [Command] = [
            EchoCommand(),
            TrueCommand(),
            FalseCommand(),
            ColonCommand(),
            PwdCommand(),
            CdCommand(),
            ExportCommand(),
            UnsetCommand(),
            ExitCommand(),
            BreakCommand(),
            ContinueCommand(),
            SetCommand(),
            ShiftCommand(),
            TestCommand(name: "test"),
            TestCommand(name: "["),
            ReturnCommand(),
            LocalCommand(),
            SourceCommand(name: "source"),
            SourceCommand(name: "."),
            DeclareCommand(name: "declare"),
            DeclareCommand(name: "typeset"),
            ReadCommand(),
            PrintfCommand(),
            TrapCommand(),
            GetoptsCommand(),
        ]
        var dict: [String: Command] = [:]
        for b in all { dict[b.name] = b }
        return dict
    }

    // MARK: Per-run state (set during `run`, used by expansion)

    var currentSource: String = ""

    // MARK: Subshell factory

    /// A fresh `Shell` suitable for running as a pipeline stage or a
    /// subshell `( … )`. Environment is copied (mutations stay local);
    /// the command registry is carried over. The caller typically
    /// assigns fresh `stdin` / `stdout` sinks to wire it into a stream
    /// channel; by default a subshell inherits the outer stdio.
    func makeSubshell() -> Shell {
        let sub = Shell(environment: environment,
                        stdout: stdout,
                        stderr: stderr,
                        commands: commands,
                        fileSystem: fileSystem)
        return sub
    }
}

// String-based callers keep working because `OutputSink` provides
// `callAsFunction(_ text: String)` — no changes needed in commands.
