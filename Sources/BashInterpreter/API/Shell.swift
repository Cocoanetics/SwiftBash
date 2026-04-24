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

    /// Byte-oriented stdout sink. Defaults to `FileHandle.standardOutput`.
    public var stdout: (Data) -> Void

    /// Byte-oriented stderr sink. Defaults to `FileHandle.standardError`.
    public var stderr: (Data) -> Void

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
                stdout: @escaping (Data) -> Void = Shell.defaultStdout,
                stderr: @escaping (Data) -> Void = Shell.defaultStderr,
                commands: [String: Command] = Shell.defaultCommands())
    {
        self.environment = environment
        self.stdout = stdout
        self.stderr = stderr
        self.commands = commands
    }

    // MARK: Default sinks

    public static let defaultStdout: (Data) -> Void = { data in
        FileHandle.standardOutput.write(data)
    }

    public static let defaultStderr: (Data) -> Void = { data in
        FileHandle.standardError.write(data)
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
    /// the command registry and stdio sinks are carried over. The
    /// caller typically overrides `stdin` / `stdout` to wire it into a
    /// stream channel.
    func makeSubshell() -> Shell {
        Shell(environment: environment,
              stdout: stdout,
              stderr: stderr,
              commands: commands)
    }
}

// MARK: - String convenience

/// Encode a `String` as UTF-8 and ship it through the byte sink.
/// Commands that only deal with text can keep writing Strings
/// unchanged.
extension Shell {
    public func stdout(_ text: String) {
        stdout(Data(text.utf8))
    }

    public func stderr(_ text: String) {
        stderr(Data(text.utf8))
    }
}
