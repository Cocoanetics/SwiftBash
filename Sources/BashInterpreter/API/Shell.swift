import Foundation
import BashSyntax

/// A minimal bash interpreter operating on ASTs from ``BashSyntax``.
///
/// The shell holds an ``Environment``, a registry of built-ins, and a pair
/// of closures for stdout / stderr. It does not spawn external processes
/// in this skeleton — only registered built-ins are runnable.
///
/// ```swift
/// let shell = Shell()
/// shell.environment["PATH"] = "/usr/bin:/bin"
/// try shell.run("echo $PATH")      // writes "/usr/bin:/bin\n" to stdout
/// ```
public final class Shell {

    /// The shell's mutable environment (variables + cwd).
    public var environment: Environment

    /// Writer for builtin stdout. Defaults to `FileHandle.standardOutput`.
    public var stdout: (String) -> Void

    /// Writer for builtin stderr. Defaults to `FileHandle.standardError`.
    public var stderr: (String) -> Void

    /// Builtins keyed by command name.
    public var commands: [String: Command]

    /// Exit status of the most recently completed command.
    public internal(set) var lastExitStatus: ExitStatus = .success

    /// Number of enclosing `while` / `until` / `for` loops currently on the
    /// call stack. Used to decide whether a `LoopControlSignal` should be
    /// propagated (in a loop) or treated as a stray `break`/`continue`
    /// and turned into a bash-style warning.
    var loopDepth: Int = 0

    public init(environment: Environment = Environment(),
                stdout: @escaping (String) -> Void = Shell.defaultStdout,
                stderr: @escaping (String) -> Void = Shell.defaultStderr,
                commands: [String: Command] = Shell.defaultCommands())
    {
        self.environment = environment
        self.stdout = stdout
        self.stderr = stderr
        self.commands = commands
    }

    // MARK: Default sinks

    public static let defaultStdout: (String) -> Void = { s in
        if let data = s.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    public static let defaultStderr: (String) -> Void = { s in
        if let data = s.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
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
}
