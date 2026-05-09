import Foundation
import BashSyntax
import ShellKit

/// SwiftBash's bash interpreter context.
///
/// Subclasses ``ShellKit/Shell`` to layer bash-specific runtime
/// state on top of the virtualised environment ShellKit owns. The
/// inherited surface — `stdin` / `stdout` / `stderr`, `environment`,
/// `commands`, `sandbox`, `networkConfig`, `processTable`,
/// `hostInfo`, `positionalParameters`, `scriptName`, `lastExitStatus`,
/// `virtualPID` — is what every command and every consumer reads;
/// the subclass-only fields are bash machinery (`errexit` /
/// `pipefail` / `shopt` options, trap tables, loop / function-call
/// depth bookkeeping, errexit guard, getopts cursor, process-
/// substitution tracking, source-position tracking).
///
/// The bash interpreter dispatches every command body through
/// ``withCurrent(_:)``, which binds **both** ShellKit's TaskLocal
/// (so plain ShellKit consumers — registered SwiftPorts CLIs, etc.
/// — see this shell's runtime context) and SwiftBash's own
/// `Shell.bashCurrent` shadow (so internal interpreter code reads bash-
/// specific fields without an explicit cast).
public final class Shell: ShellKit.Shell, @unchecked Sendable {

    // MARK: - Bash-specific runtime state

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

    // MARK: Per-run state (set during `run`, used by expansion)

    var currentSource: String = ""

    // MARK: - Script interpreters

    /// Interpreters keyed by shebang basename — `"swift-script"`,
    /// `"swift"`, `"python3"`. Consulted by the dispatcher when a
    /// path-invoked simple command (`./script.swift`,
    /// `/abs/script.foo`) is a regular file with a `#!`-shebang.
    /// Empty by default; embedders register what they want to
    /// support via ``registerScriptInterpreter(_:)`` /
    /// ``registerScriptInterpreter(name:_:)``.
    public var scriptInterpreters: [String: ScriptInterpreter] = [:]

    // MARK: - Filesystem

    /// The filesystem the shell reads and writes through. Defaults
    /// to ``RealFileSystem`` (the host's real `FileManager`). Swap in
    /// `InMemoryFileSystem` or similar to sandbox scripts.
    ///
    /// Whatever is assigned is automatically wrapped in
    /// ``VirtualBinFileSystem`` so `/bin`, `/usr/bin`, and
    /// `/usr/local/bin` always reflect this shell's command registry
    /// rather than whatever the host might (or might not) have at
    /// those paths. Wrapping is idempotent — assigning a fileSystem
    /// that's already a ``VirtualBinFileSystem`` doesn't double-wrap.
    ///
    /// **Migration note.** This is the legacy `FileSystem` protocol
    /// surface; SwiftBash will retire it in favour of ShellKit's
    /// `Sandbox` URL-gate model in a follow-up PR. For now both
    /// coexist on the bash interpreter — code that needs URL-level
    /// gating should call `ShellKit.Shell.current.sandbox?.authorize(_:)`
    /// directly and only use `fileSystem` for the legacy path-based
    /// reads/writes.
    public var fileSystem: FileSystem {
        get { _fileSystem }
        set {
            _fileSystem = (newValue is VirtualBinFileSystem)
                ? newValue
                : VirtualBinFileSystem(backing: newValue)
        }
    }
    private var _fileSystem: FileSystem

    // MARK: - Bash-typed TaskLocal

    /// Bash-typed TaskLocal that runs alongside (not on top of) the
    /// inherited ``ShellKit/Shell/current``. Inside SwiftBash's
    /// interpreter, code reads `Shell.bashCurrent` to get the bash
    /// subclass directly (so accesses like `bashCurrent.errexit`
    /// don't need a cast). Plain ShellKit consumers — registered
    /// SwiftPorts CLIs, anything that doesn't know SwiftBash exists
    /// — read `ShellKit.Shell.bashCurrent` and see the same instance via
    /// the runtime-context surface only.
    ///
    /// ``withCurrent(_:)`` binds the two in tandem on every
    /// dispatch / subshell entry, so the two accessors never get
    /// out of sync.
    ///
    /// Why two names instead of overriding `current`: Swift won't
    /// let a subclass redeclare a `@TaskLocal` static with a
    /// different element type (the projected `$current` value can't
    /// be narrowed). Separate name keeps both accessors typed
    /// correctly without runtime casts.
    @TaskLocal public static var bashCurrent: Shell = Shell()

    // MARK: - Init

    public required init(
        stdin: InputSource = .empty,
        stdout: OutputSink? = nil,
        stderr: OutputSink? = nil,
        environment: Environment = Environment(),
        positionalParameters: [String] = [],
        scriptName: String = "swift-bash",
        lastExitStatus: ExitStatus = .success,
        sandbox: Sandbox? = nil,
        networkConfig: NetworkConfig? = nil,
        hostInfo: HostInfo = .synthetic,
        processTable: ProcessTable = ProcessTable(),
        virtualPID: Int32 = 1,
        commands: [String: Command] = [:],
        processLauncher: (any ProcessLauncher)? = nil
    ) {
        // FileSystem is bash-specific (legacy protocol). The
        // VirtualBinFileSystem wrap happens after super.init.
        self._fileSystem = VirtualBinFileSystem(backing: RealFileSystem())
        super.init(
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            environment: environment,
            positionalParameters: positionalParameters,
            scriptName: scriptName,
            lastExitStatus: lastExitStatus,
            sandbox: sandbox,
            networkConfig: networkConfig,
            hostInfo: hostInfo,
            processTable: processTable,
            virtualPID: virtualPID,
            commands: commands,
            processLauncher: processLauncher)
    }

    /// Convenience initializer matching SwiftBash's pre-migration
    /// signature so existing call sites compile unchanged.
    public convenience init(environment: Environment = Environment(),
                            stdout: OutputSink? = nil,
                            stderr: OutputSink? = nil,
                            commands: [String: Command] = Shell.defaultCommands(),
                            fileSystem: FileSystem = RealFileSystem())
    {
        self.init(
            stdout: stdout ?? .forwarding(to: FileHandle.standardOutput),
            stderr: stderr ?? .forwarding(to: FileHandle.standardError),
            environment: environment,
            commands: commands)
        self.fileSystem = fileSystem
        // Advertise the running interpreter to scripts that probe bash
        // version. These describe SwiftBash itself, not anything the
        // caller's environment should be able to override.
        self.environment.variables["BASH"] = SwiftBashVersion.bashPath
        self.environment.variables["BASH_VERSION"] = SwiftBashVersion.bashVersion
        self.environment.arrays["BASH_VERSINFO"] = BashArray(
            dense: SwiftBashVersion.bashVersionInfo)
        // Sensible "I am a real bash session" defaults for the
        // variables a bash shell normally sets at startup but that a
        // parent process *doesn't* pass down. Caller-supplied values
        // win.
        for (key, value) in Self.runtimeEnvDefaults() {
            if self.environment.variables[key] == nil {
                self.environment.variables[key] = value
            }
        }
        if self.environment.variables["PWD"] == nil {
            self.environment.variables["PWD"] = self.environment.workingDirectory
        }
    }

    /// Default values for environment variables a real bash shell sets
    /// at startup. Applied in the convenience init when the supplied
    /// environment doesn't already provide a value — caller's choice
    /// always wins.
    private static func runtimeEnvDefaults() -> [(String, String)] {
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

    // MARK: - hostInfo override (re-syncs env vars on assignment)

    /// Override the inherited `hostInfo` to attach a `didSet`
    /// observer that re-syncs the matching environment variables —
    /// `$HOSTNAME`, `$USER`, `$LOGNAME`, `$HOSTTYPE`, `$MACHTYPE` —
    /// so `whoami`'s answer and `$USER`'s value never disagree.
    ///
    /// Embedders that want to preserve a deliberate custom override
    /// (e.g. setting `HOSTNAME=foo` for a specific test) assign it
    /// AFTER setting `hostInfo`.
    public override var hostInfo: HostInfo {
        didSet {
            environment.variables["HOSTNAME"] = hostInfo.hostName
            environment.variables["USER"] = hostInfo.userName
            environment.variables["LOGNAME"] = hostInfo.userName
            environment.variables["HOSTTYPE"] = hostInfo.machine
            environment.variables["MACHTYPE"] =
                "\(hostInfo.machine)-apple-\(hostInfo.kernelName.lowercased())"
        }
    }

    // MARK: - Default registry

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

    // MARK: - Subshell factory

    /// A fresh `Shell` suitable for running as a pipeline stage or a
    /// subshell `( … )`. Every property that should be inherited is
    /// cloned — runtime context (delegated to super) plus the
    /// bash-specific *configuration* fields below.
    ///
    /// Bash-specific *per-execution / per-shell-instance* state
    /// (`errexitGuard`, `skipNextErrexitCheck`, `runningTraps`,
    /// `getoptsCharIndex`, `loopDepth`, `functionCallDepth`,
    /// `localVarStack`, `pendingProcessSubs`, `currentCommandRange`)
    /// is **not** carried over — a subshell starts fresh, matching
    /// real bash. In particular, `loopDepth` MUST reset so that
    /// `(break)` inside a loop body raises bash's "only meaningful
    /// in a loop" diagnostic instead of unwinding the parent's loop
    /// (Codex review on PR #11). Same logic applies to
    /// `functionCallDepth` / `localVarStack`: a subshell isn't
    /// inside any function frame.
    public override func copy() -> Self {
        // ShellKit's base `copy()` returns `Self`, implemented via
        // `type(of: self).init(...)` — so the runtime type already
        // matches the static type and no cast is needed. (An
        // earlier `guard let bash = sub as? Self` provoked a
        // "conditional cast from 'Self' to 'Self' always succeeds"
        // warning across every translation unit that called copy().)
        let bash = super.copy()
        // Inheritable bash configuration. Mirror the pre-ShellKit
        // copy() exactly — anything not listed here resets to its
        // initializer default in the new subshell instance.
        bash.fileSystem = fileSystem
        bash.errexit = errexit
        bash.pipefail = pipefail
        bash.nounset = nounset
        bash.shoptOptions = shoptOptions
        bash.traps = traps
        bash.currentSource = currentSource
        bash.scriptInterpreters = scriptInterpreters
        return bash
    }

    // MARK: - Binding helper

    /// Run `body` with this Shell installed as both ``Shell/current``
    /// (the bash-typed shadow) AND ``ShellKit/Shell/current`` (the
    /// runtime-context view ShellKit consumers use). Both bind to
    /// the SAME instance, so mutations are visible through either
    /// accessor.
    public override func withCurrent<T: Sendable>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        return try await Shell.$bashCurrent.withValue(self) {
            try await ShellKit.Shell.$current.withValue(self) {
                try await body()
            }
        }
    }
}

// String-based callers keep working because `OutputSink` provides
// `callAsFunction(_ text: String)` — no changes needed in commands.
