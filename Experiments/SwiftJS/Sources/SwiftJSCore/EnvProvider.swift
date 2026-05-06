import Foundation
import BashInterpreter

/// Provides the values JS sees through `process.env`.
///
/// Three backends ship in this experiment:
///
///   - ``OSEnvProvider``         — the host process environment.
///                                 Mutations call `setenv(...)` so
///                                 spawned children see them. This is
///                                 the default and matches Node.
///
///   - ``DictionaryEnvProvider`` — an in-memory dict the embedder
///                                 owns. Useful for tests, sandboxed
///                                 hosts, and "give the JS only the
///                                 variables I list" scenarios.
///
///   - ``ShellEnvProvider``      — wraps a SwiftBash ``Shell``, so
///                                 JS sees the shell's environment
///                                 (which may have come from
///                                 ``Environment.synthetic`` for full
///                                 sandbox, or from bash code that
///                                 set variables in the shell).
///                                 Mutations propagate back into the
///                                 shell, so a subsequent bash
///                                 `echo "$X"` sees what JS wrote.
public protocol EnvProvider: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
    var allKeys: [String] { get }
}

// MARK: - Default: real process env

/// Backed by the host process's environment. Mutations call
/// `setenv` / `unsetenv` so child processes (Foundation `Process`,
/// `Bash` builtins, etc.) see the same view.
public final class OSEnvProvider: EnvProvider {
    public init() {}
    public func get(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }
    public func set(_ key: String, _ value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
    public var allKeys: [String] {
        Array(ProcessInfo.processInfo.environment.keys)
    }
}

// MARK: - Mock / sandbox: in-memory dict

/// In-memory environment. Mutations stay inside the JS runtime;
/// the host process env is untouched. Use to give a script a
/// curated subset of variables.
public final class DictionaryEnvProvider: EnvProvider {
    private var storage: [String: String]
    public init(_ initial: [String: String] = [:]) { storage = initial }
    public func get(_ key: String) -> String? { storage[key] }
    public func set(_ key: String, _ value: String?) {
        if let value { storage[key] = value }
        else { storage.removeValue(forKey: key) }
    }
    public var allKeys: [String] { Array(storage.keys) }
}

// MARK: - SwiftBash Shell-backed

/// Routes env reads/writes through a SwiftBash ``Shell``. This
/// gives a JS script a live view of whatever the shell sees —
/// including variables defined by bash code that ran earlier in
/// the same process. Two scripts (a bash one and a JS one) can
/// share state through the shell's environment without ever
/// touching the host process env.
public final class ShellEnvProvider: EnvProvider {
    public let shell: Shell
    public init(_ shell: Shell) { self.shell = shell }
    public func get(_ key: String) -> String? {
        shell.environment[key]
    }
    public func set(_ key: String, _ value: String?) {
        shell.environment[key] = value
    }
    public var allKeys: [String] {
        Array(shell.environment.variables.keys)
    }
}
