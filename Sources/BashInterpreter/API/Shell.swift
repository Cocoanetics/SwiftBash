// Public API surface for the bash interpreter — splitting would
// scatter the Shell type's documented surface across multiple files.
// swiftlint:disable file_length
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
    public internal(set) var currentCommandRange: Range<Int>?

    /// Compute the 1-indexed line number containing `position` in
    /// ``currentSource``. Returns 1 for any out-of-range position.
    public func lineNumber(for position: Int) -> Int {
        let chars = Array(currentSource)
        let limit = min(max(0, position), chars.count)
        var line = 1
        for offset in 0..<limit where chars[offset] == "\n" {
            line += 1
        }
        return line
    }

    /// When `true`, ``errorLocationPrefix()`` drops the `: line N:`
    /// portion. Embedders running each user keystroke as its own
    /// `Shell.run(line)` call set this so error diagnostics read
    /// `iBash: ./foo: not found` rather than `iBash: line 1: ./foo:
    /// not found` — real bash's interactive REPL behaves the same
    /// way. Defaults to `false` (script-style prefix).
    public var interactive: Bool = false

    /// `script:line:` prefix for diagnostics, or just `script:` when
    /// no command is currently being executed. When ``interactive``
    /// is `true`, the line number is suppressed since each REPL
    /// input is its own implicit line 1.
    public func errorLocationPrefix() -> String {
        if let range = currentCommandRange, !interactive {
            return "\(scriptName): line \(lineNumber(for: range.lowerBound)): "
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
    public var nounset: Bool = false

    /// `set -x` / `set -o xtrace` — when `true`, the shell prints
    /// each simple command (after expansion) to stderr prefixed
    /// with the expanded value of `$PS4` (default `"+ "`). The trace
    /// hook lives in ``executeSimpleCommand``; embedders just flip
    /// this flag to opt in. Propagates through ``copy()`` so a
    /// pipeline stage inherits its parent's trace state.
    public var xtrace: Bool = false

    /// `set -v` / `set -o verbose` — when `true`, the shell echoes
    /// each command's source slice to stderr immediately before
    /// executing it. Differs from ``xtrace`` in that the *source*
    /// is echoed (pre-expansion) rather than the *resolved* argv.
    /// Propagates through ``copy()``.
    public var verbose: Bool = false

    // MARK: - Command registry (file-backed and built-in)

    /// File-backed commands keyed by their canonical install path.
    /// The authoritative store for ``install(_:)`` /
    /// ``install(_:at:)`` — the dispatcher consults this through
    /// ``PathResolver`` after walking `$PATH`. A single basename can
    /// have multiple entries (e.g. `/bin/foo` and
    /// `/usr/local/bin/foo`); `$PATH` order picks the winner.
    public internal(set) var commandsByPath: [String: Command] = [:]

    /// Reverse index from basename to every install path that lands
    /// at that basename, in install order. ``PathResolver`` walks
    /// `$PATH` and tests whether any of these paths matches. Always
    /// kept in sync with ``commandsByPath`` by the install/uninstall
    /// methods.
    public internal(set) var pathsByBasename: [String: [String]] = [:]

    /// Pure shell built-ins — `cd`, `export`, `eval`, `set`, … —
    /// installed via ``installShellBuiltin(_:)``. These have no file
    /// on disk and are NOT PATH-searchable: the dispatcher consults
    /// this map before walking `$PATH`, and absolute / relative path
    /// invocations skip it entirely (so `/bin/echo` runs the file
    /// form, never the built-in).
    public internal(set) var shellBuiltins: [String: Command] = [:]

    /// `shopt`-controlled options. Most map directly to glob/expansion
    /// behaviour; unknown options accept assignments but are otherwise
    /// no-ops, matching bash's permissive defaults.
    public var shoptOptions: [String: Bool] = [
        "nullglob": false,    // unmatched globs disappear (vs. literal pass-through)
        "globstar": false,    // `**` matches across directory boundaries
        "extglob": false,    // enables `?(p) *(p) +(p) @(p) !(p)` patterns
        "nocaseglob": false,  // case-insensitive globbing
        "dotglob": false,    // include leading-dot files in globs
        "nocasematch": false // case-insensitive `[[ s == p ]]` and `case`
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

    // MARK: - Interactive UI

    /// Embedder hook for builtins that want to drive a host-side
    /// interactive view (`less`, `more`, future `nano`/`fzf`/`man`).
    /// `nil` — the default — means no host UI is available, so the
    /// builtins fall back to non-interactive behaviour (real `less`
    /// on a non-TTY just cats its input).
    public var interactivePresenter: (any InteractivePresenter)?

    /// `true` when this shell's `stdout` writes to an interactive
    /// surface (a terminal emulator, a SwiftUI text view, …) rather
    /// than a file/pipe/discard. Pager builtins consult this to
    /// decide whether to engage their interactive UI (via
    /// ``interactivePresenter``) or pass content through unchanged
    /// — same logic real `less(1)` uses via `isatty(1)`.
    ///
    /// Pipeline stages whose stdout is the inter-stage `OutputSink`
    /// override this to `false` so `git log | less | cat` makes
    /// `less` behave as `cat`, matching real bash.
    ///
    /// Defaults to `false` (the safe answer for non-interactive
    /// embedders like batch scripts and test harnesses). Embedders
    /// that connect a UI sink set this to `true`.
    public var stdoutIsTTY: Bool = false

    /// `true` when this shell's `stdin` reads from an interactive
    /// surface. Mirrors ``stdoutIsTTY`` for fd 0. `test -t 0` /
    /// `[ -t 0 ]` consult this, and the pipeline executor flips it
    /// off on consumer stages so `cmd1 | cmd2` makes `cmd2` see a
    /// non-TTY stdin.
    public var stdinIsTTY: Bool = false

    /// `true` when this shell's `stderr` writes to an interactive
    /// surface. Mirrors ``stdoutIsTTY`` for fd 2. `test -t 2` /
    /// `[ -t 2 ]` consult this, and the pipeline executor flips
    /// it off on `|&`-merged producer stages whose stderr is the
    /// inter-stage `OutputSink`.
    public var stderrIsTTY: Bool = false

    /// One pending `<(cmd)` or `>(cmd)` substitution.
    struct ProcessSub: Sendable {
        let kind: ProcessSubKind
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
    /// Whatever is assigned is automatically wrapped in an
    /// ``OverlayFileSystem`` carrying a default ``BinCatalogOverlay``
    /// so `/bin`, `/usr/bin`, and `/usr/local/bin` always reflect
    /// this shell's command registry rather than whatever the host
    /// might (or might not) have at those paths. Embedders that want
    /// additional virtual content (an `/examples` tree from an app
    /// bundle, for instance) can assign their own pre-built
    /// `OverlayFileSystem` with the desired provider list — the
    /// setter detects an already-wrapped FS and doesn't double-wrap.
    public var fileSystem: FileSystem {
        get { _fileSystem }
        set {
            _fileSystem = (newValue is OverlayFileSystem)
                ? newValue
                : OverlayFileSystem(
                    backing: newValue,
                    providers: [BinCatalogOverlay()])
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
        // OverlayFileSystem wrap happens after super.init.
        self._fileSystem = OverlayFileSystem(
            backing: RealFileSystem(),
            providers: [BinCatalogOverlay()])
        // SwiftBash is sandbox-by-default and never spawns real OS
        // subprocesses. Resolve `nil` to ``BashProcessLauncher`` so a
        // launcher consumer (a SwiftScript / SwiftJSCore script
        // calling `Shell.current.processLauncher.launch(...)`)
        // reaches this shell's command registry instead of falling
        // through to `DefaultProcessLauncher`'s real-exec path that
        // ShellKit installs by default.
        super.init(
            stdin: stdin,
            stdout: stdout ?? .forwarding(to: FileHandle.standardOutput),
            stderr: stderr ?? .forwarding(to: FileHandle.standardError),
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
            processLauncher: processLauncher ?? BashProcessLauncher())
        // Bare construction with no caller-supplied commands → install
        // SwiftBash's default built-in surface (`cd`, `export`, `eval`,
        // the hybrid `echo` / `printf` / `pwd` pair, etc.) AND apply
        // the runtime env defaults (`PATH=/usr/local/bin:/usr/bin:/bin`,
        // `HOME`, `BASH`, `BASH_VERSION`, …). `Shell.copy()` calls
        // `init(commands: <parent>.commands, …)` with a non-empty dict
        // so subshells inherit cleanly without re-installing defaults
        // on top of their parent's snapshot.
        if commands.isEmpty {
            self.environment.variables["BASH"] = SwiftBashVersion.bashPath
            self.environment.variables["BASH_VERSION"] = SwiftBashVersion.bashVersion
            self.environment.arrays["BASH_VERSINFO"] = BashArray(
                dense: SwiftBashVersion.bashVersionInfo)
            for (key, value) in Self.runtimeEnvDefaults()
                where self.environment.variables[key] == nil {
                self.environment.variables[key] = value
            }
            if self.environment.variables["PWD"] == nil {
                self.environment.variables["PWD"] = self.environment.workingDirectory
            }
            installDefaultBuiltins()
        }
    }

    /// Convenience initializer with ``environment`` as the first
    /// labelled argument — matches the historical call shape
    /// `Shell(environment:, stdout:, stderr:)` used throughout the
    /// existing test suite. Swift requires labelled args to follow
    /// declaration order, so the designated initializer (with
    /// ``stdin`` first) doesn't accept calls that put ``environment``
    /// before ``stdout``/``stderr``.
    public convenience init(
        environment: Environment,
        stdout: OutputSink? = nil,
        stderr: OutputSink? = nil
    ) {
        self.init(
            stdin: .empty,
            stdout: stdout,
            stderr: stderr,
            environment: environment)
    }

    /// Convenience initializer for callers that need to swap in a
    /// custom ``FileSystem`` at construction time. Defers to the
    /// designated initializer (which installs the default built-ins
    /// and the runtime env defaults when `commands` is empty), then
    /// assigns the supplied filesystem.
    public convenience init(
        fileSystem: FileSystem,
        stdout: OutputSink? = nil,
        stderr: OutputSink? = nil,
        environment: Environment = Environment()
    ) {
        self.init(
            stdin: .empty,
            stdout: stdout,
            stderr: stderr,
            environment: environment)
        self.fileSystem = fileSystem
    }

    /// Default values for environment variables a real bash shell sets
    /// at startup. Applied in the designated init when `commands` is
    /// empty (the "fresh shell" path) and the supplied environment
    /// doesn't already carry a value — caller's choice always wins.
    private static func runtimeEnvDefaults() -> [(String, String)] {
        return [
            // `/usr/local/bin` shadows `/usr/bin` and `/bin` — matches
            // macOS convention so a user-installed skill at
            // `/usr/local/bin/foo` overrides a bundled `/bin/foo` by
            // default. Embedders that want a different shape set
            // `environment.variables["PATH"]` before running.
            ("PATH", "/usr/local/bin:/usr/bin:/bin"),
            ("HOME", "/home/\(HostInfo.synthetic.userName)"),
            ("USER", HostInfo.synthetic.userName),
            ("LOGNAME", HostInfo.synthetic.userName),
            ("HOSTNAME", HostInfo.synthetic.hostName),
            ("SHELL", "/bin/bash"),
            ("TERM", "dumb"),
            ("LANG", "C.UTF-8"),
            ("LC_ALL", "C.UTF-8"),
            ("IFS", " \t\n"),
            ("OPTIND", "1"),
            ("OSTYPE", "darwin"),
            ("MACHTYPE", "\(HostInfo.synthetic.machine)-apple-darwin"),
            ("HOSTTYPE", HostInfo.synthetic.machine),
            ("PS1", #"\s-\v\$ "#),
            ("PS2", "> "),
            ("PS4", "+ "),
            ("SHLVL", "1")
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

    /// Install SwiftBash's built-in command surface on this shell.
    /// Pure shell built-ins (`cd`, `export`, `eval`, …) go through
    /// ``installShellBuiltin(_:)``; hybrid commands (`echo`, `printf`,
    /// `pwd`, `test`, `[`, `true`, `false`, `wait`) install BOTH as a
    /// shell built-in (wins for bare invocation) AND as a file at
    /// their `BinCatalog` path (reachable via absolute path and
    /// surfaced by `which`); pure file-backed commands (`bash`, `sh`,
    /// `dash`) only install at their catalog path.
    ///
    /// Called automatically from the designated initializer when the
    /// caller-supplied `commands` dict is empty; tests / embedders
    /// that want a clean slate can clear the install storage after
    /// construction or pass a non-empty `commands` dict to opt out.
    public func installDefaultBuiltins() {
        // Pure shell built-ins: no file on disk, not PATH-searchable.
        let pureBuiltins: [Command] = [
            ColonCommand(),
            CdCommand(),
            ExportCommand(),
            UnsetCommand(),
            ExitCommand(),
            EvalCommand(),
            LetCommand(),
            ShoptCommand(),
            MapfileCommand(name: "mapfile"),
            MapfileCommand(name: "readarray"),
            BreakCommand(),
            ContinueCommand(),
            SetCommand(),
            ShiftCommand(),
            ReturnCommand(),
            LocalCommand(),
            SourceCommand(name: "source"),
            SourceCommand(name: "."),
            DeclareCommand(name: "declare"),
            DeclareCommand(name: "typeset"),
            ReadCommand(),
            TrapCommand(),
            GetoptsCommand(),
            CompgenCommand()
        ]
        for builtin in pureBuiltins {
            installShellBuiltin(builtin)
        }

        // Hybrid commands: a built-in wins for the bare name, and a
        // file form at the catalog path is reachable via absolute
        // invocation and via `which`. Both forms share the same Swift
        // implementation — real bash's file form is a separate binary,
        // but inside a virtualised shell the behaviour overlaps
        // closely enough that a single instance covers both.
        let hybrids: [Command] = [
            EchoCommand(),
            TrueCommand(),
            FalseCommand(),
            PwdCommand(),
            WaitCommand(),
            TestCommand(name: "test"),
            TestCommand(name: "["),
            PrintfCommand()
        ]
        for hybrid in hybrids {
            installShellBuiltin(hybrid)
            install(hybrid)
        }

        // File-only commands at their catalog paths.
        install(BashCommand(name: "bash"))
        install(BashCommand(name: "sh"))
        install(BashCommand(name: "dash"))
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
        // Install paths and shell built-ins propagate exactly so a
        // subshell sees the same command surface as its parent (incl.
        // PATH-aware shadowing). ShellKit's `super.copy()` already
        // carried `commands` forward as the basename mirror.
        bash.commandsByPath = commandsByPath
        bash.pathsByBasename = pathsByBasename
        bash.shellBuiltins = shellBuiltins
        bash.errexit = errexit
        bash.pipefail = pipefail
        bash.nounset = nounset
        bash.xtrace = xtrace
        bash.verbose = verbose
        bash.shoptOptions = shoptOptions
        bash.traps = traps
        bash.currentSource = currentSource
        bash.scriptInterpreters = scriptInterpreters
        bash.interactivePresenter = interactivePresenter
        bash.stdoutIsTTY = stdoutIsTTY
        bash.stdinIsTTY = stdinIsTTY
        bash.stderrIsTTY = stderrIsTTY
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

/// Direction of a `<(cmd)` / `>(cmd)` process substitution.
enum ProcessSubKind: Sendable { case input, output }
