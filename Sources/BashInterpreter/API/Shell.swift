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
    ///
    /// Whatever is assigned is automatically wrapped in
    /// ``VirtualBinFileSystem`` so `/bin`, `/usr/bin`, and
    /// `/usr/local/bin` always reflect this shell's command registry
    /// rather than whatever the host might (or might not) have at
    /// those paths. Wrapping is idempotent — assigning a fileSystem
    /// that's already a ``VirtualBinFileSystem`` doesn't double-wrap.
    public var fileSystem: FileSystem {
        get { _fileSystem }
        set {
            _fileSystem = (newValue is VirtualBinFileSystem)
                ? newValue
                : VirtualBinFileSystem(backing: newValue)
        }
    }
    private var _fileSystem: FileSystem

    /// Positional parameters — `$1` is `positionalParameters[0]`, etc.
    /// Set this directly, or use `set -- a b c` from a script. The
    /// CLI's `swift-bash exec script.sh arg1 arg2` populates them.
    public var positionalParameters: [String] = []

    /// `$0` — the script or shell name. Defaults to "swift-bash".
    public var scriptName: String = "swift-bash"

    /// Source range of the simple command currently being dispatched —
    /// used to render `script.sh: line N:` prefixes on errors so they
    /// match bash's formatting. Set/cleared by ``executeSimpleCommand``.
    public internal(set) var currentCommandRange: Range<Int>? = nil

    /// Compute the 1-indexed line number containing `position` in
    /// ``currentSource``. Returns 1 for any out-of-range position.
    public func lineNumber(for position: Int) -> Int {
        let chars = Array(currentSource)
        let limit = min(max(0, position), chars.count)
        var line = 1
        for i in 0..<limit {
            if chars[i] == "\n" { line += 1 }
        }
        return line
    }

    /// `script:line:` prefix for diagnostics, or just `script:` when
    /// no command is currently being executed.
    public func errorLocationPrefix() -> String {
        if let r = currentCommandRange {
            return "\(scriptName): line \(lineNumber(for: r.lowerBound)): "
        }
        return "\(scriptName): "
    }

    /// Exit status of the most recently completed command.
    public internal(set) var lastExitStatus: ExitStatus = .success

    /// Network policy used by `curl` and any other network-using
    /// command. **`nil` means default-deny** — curl reports
    /// `Network access denied: URL not in allow-list` and exits with
    /// status 7. To enable, set a ``NetworkConfig`` with concrete
    /// ``NetworkConfig/allowedURLPrefixes`` entries.
    public var networkConfig: NetworkConfig? = nil

    /// Virtual process table — `&` background jobs and the four
    /// `ps`/`kill`/`pgrep`/`pkill` commands all operate against this
    /// in-memory table. There is intentionally no path to the host's
    /// real process table.
    public var processTable: ProcessTable = ProcessTable()

    /// `$$` — this shell's virtual PID. Synthetic, not the host's.
    public var virtualPID: Int32 = 1

    /// Identity reported by `whoami`, `hostname`, `id`, `uname`,
    /// `df`, and any other host-identity-disclosing command. Default
    /// is ``HostInfo/synthetic`` — leaks nothing. Embedders that
    /// genuinely want the running machine's identity assign
    /// ``HostInfo/real()``.
    ///
    /// Setting this also re-syncs the matching environment variables
    /// (`$HOSTNAME`, `$USER`, `$LOGNAME`, `$HOME`, `$HOSTTYPE`,
    /// `$MACHTYPE`) so `whoami`'s answer and `$USER`'s value never
    /// disagree. If you want to preserve a custom override (e.g. you
    /// set `HOSTNAME=foo` deliberately), assign it AFTER setting
    /// `hostInfo`.
    public var hostInfo: HostInfo = .synthetic {
        didSet {
            environment.variables["HOSTNAME"] = hostInfo.hostName
            environment.variables["USER"] = hostInfo.userName
            environment.variables["LOGNAME"] = hostInfo.userName
            environment.variables["HOSTTYPE"] = hostInfo.machine
            environment.variables["MACHTYPE"] =
                "\(hostInfo.machine)-apple-\(hostInfo.kernelName.lowercased())"
        }
    }

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

    /// `shopt`-controlled options. Most map directly to glob/expansion
    /// behaviour; unknown options accept assignments but are otherwise
    /// no-ops, matching bash's permissive defaults.
    public var shoptOptions: [String: Bool] = [
        "nullglob": false,    // unmatched globs disappear (vs. literal pass-through)
        "globstar": false,    // `**` matches across directory boundaries
        "extglob":  false,    // enables `?(p) *(p) +(p) @(p) !(p)` patterns
        "nocaseglob": false,  // case-insensitive globbing
        "dotglob":  false,    // include leading-dot files in globs
        "nocasematch": false, // case-insensitive `[[ s == p ]]` and `case`
    ]

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
        // Initialise the underlying storage directly to go through the
        // wrap-if-needed setter logic exactly once.
        self._fileSystem = (fileSystem is VirtualBinFileSystem)
            ? fileSystem
            : VirtualBinFileSystem(backing: fileSystem)
        // Advertise the running interpreter to scripts that probe bash
        // version. These describe SwiftBash itself, not anything the
        // caller's environment should be able to override — the only
        // useful answer is "you're running under SwiftBash 4.x-target".
        self.environment.variables["BASH"] = SwiftBashVersion.bashPath
        self.environment.variables["BASH_VERSION"] = SwiftBashVersion.bashVersion
        self.environment.arrays["BASH_VERSINFO"] = BashArray(
            dense: SwiftBashVersion.bashVersionInfo)
        // Sensible "I am a real bash session" defaults for the
        // variables a bash shell normally sets at startup but that
        // a parent process *doesn't* pass down. Without these, a
        // script's `[ -n "$IFS" ]`, `getopts`-without-init, and
        // platform sniffs (`case $OSTYPE in linux*) … esac`) would
        // hit unexpected empty values. Anything the caller already
        // set in the supplied Environment wins.
        for (key, value) in Self.runtimeEnvDefaults() {
            if self.environment.variables[key] == nil {
                self.environment.variables[key] = value
            }
        }
        // PWD tracks the shell's logical cwd. Initialise from
        // `workingDirectory` if the caller didn't supply one.
        if self.environment.variables["PWD"] == nil {
            self.environment.variables["PWD"] = self.environment.workingDirectory
        }
    }

    /// Default values for environment variables a real bash shell sets
    /// at startup. Applied in ``init(environment:stdout:stderr:commands:fileSystem:)``
    /// only when the supplied environment doesn't already provide a
    /// value — caller's choice always wins.
    private static func runtimeEnvDefaults() -> [(String, String)] {
        // Use synthetic-aligned defaults rather than introspecting
        // the host: `Shell()` should leak nothing about the machine
        // it's running on. Embedders that want real values either
        // pass `Environment.current()` (which keeps inherited PATH
        // / HOME / TERM / …) or assign `Shell.hostInfo = .real()`
        // and re-set the relevant variables themselves.
        return [
            ("PATH",      "/usr/bin:/bin"),
            ("HOME",      "/home/\(HostInfo.synthetic.userName)"),
            ("USER",      HostInfo.synthetic.userName),
            ("LOGNAME",   HostInfo.synthetic.userName),
            ("HOSTNAME",  HostInfo.synthetic.hostName),
            ("SHELL",     "/bin/bash"),
            ("TERM",      "dumb"),
            ("LANG",      "C.UTF-8"),
            ("LC_ALL",    "C.UTF-8"),
            ("IFS",       " \t\n"),
            ("OPTIND",    "1"),
            ("OSTYPE",    "darwin"),
            ("MACHTYPE",  "\(HostInfo.synthetic.machine)-apple-darwin"),
            ("HOSTTYPE",  HostInfo.synthetic.machine),
            ("PS1",       #"\s-\v\$ "#),
            ("PS2",       "> "),
            ("PS4",       "+ "),
            ("SHLVL",     "1"),
        ]
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
            EvalCommand(),
            LetCommand(),
            ShoptCommand(),
            WaitCommand(),
            MapfileCommand(name: "mapfile"),
            MapfileCommand(name: "readarray"),
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
            BashCommand(name: "bash"),
            BashCommand(name: "sh"),
            BashCommand(name: "dash"),
        ]
        var dict: [String: Command] = [:]
        for b in all { dict[b.name] = b }
        return dict
    }

    // MARK: Per-run state (set during `run`, used by expansion)

    var currentSource: String = ""

    // MARK: Task-local current shell

    /// The shell that nested code (commands, expansion, traps) reads
    /// from. The top-level ``run(_:)`` wraps execution in
    /// ``Shell/$current.withValue(self)``; subshells push their copy
    /// the same way. As a result, every option held on a Shell —
    /// `networkConfig`, `fileSystem`, `commands`, `shoptOptions`,
    /// `errexit`, `environment`, … — propagates automatically across
    /// pipeline stages, `(…)` subshells, and child Tasks via Swift's
    /// `@TaskLocal` propagation.
    ///
    /// The default value is a placeholder Shell with empty defaults;
    /// it should never be observed in practice because every entry
    /// point binds the real Shell first.
    @TaskLocal public static var current: Shell = Shell()

    // MARK: Subshell factory

    /// A fresh `Shell` suitable for running as a pipeline stage or a
    /// subshell `( … )`. Every property that should be inherited is
    /// cloned here — this is the **single place** to update when
    /// adding a new shell-scoped option.
    ///
    /// Mutations on the returned shell don't affect the receiver; the
    /// two are fully independent value snapshots (with reference-typed
    /// sinks like `stdout` / `stderr` shared so the subshell's output
    /// flows to the same destination).
    public func copy() -> Shell {
        let sub = Shell(environment: environment,
                        stdout: stdout,
                        stderr: stderr,
                        commands: commands,
                        fileSystem: fileSystem)
        // Inheritable runtime / configuration. Anything that should
        // survive into a subshell or pipeline stage gets cloned here.
        sub.networkConfig = networkConfig
        sub.shoptOptions = shoptOptions
        sub.errexit = errexit
        sub.pipefail = pipefail
        sub.nounset = nounset
        sub.scriptName = scriptName
        sub.positionalParameters = positionalParameters
        sub.traps = traps
        sub.currentSource = currentSource
        sub.lastExitStatus = lastExitStatus
        sub.stdin = stdin
        // Background jobs spawned in a subshell stay registered in
        // the *parent's* table so the parent's `wait` can see them.
        // Reference-share, not clone.
        sub.processTable = processTable
        sub.virtualPID = virtualPID
        sub.hostInfo = hostInfo
        return sub
    }

    /// Run `body` with this Shell installed as ``Shell/current``.
    /// Used internally by ``run(_:)`` and by every subshell entry
    /// point. Public so embedders can do `Shell.current` lookups in
    /// their own helpers without going through the dispatcher.
    public func withCurrent<T: Sendable>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        return try await Self.$current.withValue(self) { try await body() }
    }
}

// String-based callers keep working because `OutputSink` provides
// `callAsFunction(_ text: String)` — no changes needed in commands.
