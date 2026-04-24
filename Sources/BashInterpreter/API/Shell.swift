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
    public var builtins: [String: Builtin]

    /// Exit status of the most recently completed command.
    public internal(set) var lastExitStatus: ExitStatus = .success

    public init(environment: Environment = Environment(),
                stdout: @escaping (String) -> Void = Shell.defaultStdout,
                stderr: @escaping (String) -> Void = Shell.defaultStderr,
                builtins: [String: Builtin] = Shell.defaultBuiltins())
    {
        self.environment = environment
        self.stdout = stdout
        self.stderr = stderr
        self.builtins = builtins
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

    public static func defaultBuiltins() -> [String: Builtin] {
        let all: [Builtin] = [
            EchoBuiltin(),
            TrueBuiltin(),
            FalseBuiltin(),
            ColonBuiltin(),
            PwdBuiltin(),
            CdBuiltin(),
            ExportBuiltin(),
            UnsetBuiltin(),
            ExitBuiltin(),
        ]
        var dict: [String: Builtin] = [:]
        for b in all { dict[b.name] = b }
        return dict
    }

    // MARK: Per-run state (set during `run`, used by expansion)

    var currentSource: String = ""
}
