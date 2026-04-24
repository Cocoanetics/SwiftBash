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

    /// Exit status of the most recently completed command.
    public internal(set) var lastExitStatus: ExitStatus = .success

    /// Depth of enclosing `while`/`until`/`for` loops on the call stack.
    /// See `LoopControlSignal` for why this matters.
    var loopDepth: Int = 0

    public init(environment: Environment = Environment(),
                stdout: OutputSink? = nil,
                stderr: OutputSink? = nil,
                commands: [String: Command] = Shell.defaultCommands())
    {
        self.environment = environment
        self.stdout = stdout ?? .forwarding(to: FileHandle.standardOutput)
        self.stderr = stderr ?? .forwarding(to: FileHandle.standardError)
        self.commands = commands
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
                        commands: commands)
        return sub
    }
}

// String-based callers keep working because `OutputSink` provides
// `callAsFunction(_ text: String)` — no changes needed in commands.
