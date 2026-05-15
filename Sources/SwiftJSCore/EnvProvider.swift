#if !os(Windows)

import Foundation
import BashInterpreter

#if canImport(WinSDK)
// `_putenv_s` lives in ucrt; WinSDK re-exports it. POSIX
// `setenv`/`unsetenv` aren't part of MSVCRT.
import WinSDK
#endif

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
        #if os(Windows)
        // ucrt's `_putenv_s(name, "")` is the documented way to
        // unset; same call shape covers both branches.
        _ = _putenv_s(key, value ?? "")
        #else
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        #endif
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
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
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

// MARK: - Argv

/// Provides what JS sees through `process.argv`. The shape
/// is Node-flavoured: `[interpreter, script, ...userArgs]`.
///
///   - ``StaticArgvProvider`` — fixed `[String]` set at startup.
///                              The default; matches Node.
///   - ``ShellArgvProvider``  — wraps a SwiftBash ``Shell``'s
///                              `positionalParameters`.
///                              `process.argv.slice(2)` on the
///                              JS side maps to `$1, $2, …` on
///                              the bash side. Mutations made
///                              from JS to either end of the
///                              array are reflected in the shell.
public protocol ArgvProvider: AnyObject {
    func argv() -> [String]
    func setArgv(_ value: [String])
}

public final class StaticArgvProvider: ArgvProvider {
    private var storage: [String]
    public init(_ argv: [String]) { storage = argv }
    public func argv() -> [String] { storage }
    public func setArgv(_ value: [String]) { storage = value }
}

/// argv = [interpreter, script, ...shell.positionalParameters].
/// Reads are live; writes to argv elements at index >= 2 propagate
/// back into `shell.positionalParameters`.
public final class ShellArgvProvider: ArgvProvider {
    public let shell: Shell
    /// The first two slots — `argv[0]` (interpreter) and `argv[1]`
    /// (script path) — aren't bash-positional concepts, so we hold
    /// them outside the shell.
    private let interpreter: String
    private let scriptPath: String
    public init(_ shell: Shell, interpreter: String = "swift-js", scriptPath: String = "") {
        self.shell = shell
        self.interpreter = interpreter
        self.scriptPath = scriptPath
    }
    public func argv() -> [String] {
        [interpreter, scriptPath] + shell.positionalParameters
    }
    public func setArgv(_ value: [String]) {
        // Anything past argv[2] becomes the new positionals.
        shell.positionalParameters = Array(value.dropFirst(2))
    }
}
#endif  // !os(Windows)
