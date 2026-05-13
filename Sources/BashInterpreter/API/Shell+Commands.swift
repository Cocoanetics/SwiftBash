import Foundation
import ShellKit

extension Shell {

    /// Register a ``Command`` under its own `name`, replacing any
    /// existing entry for that name.
    ///
    /// ```swift
    /// struct GreetCommand: Command {
    ///     let name = "greet"
    ///     func run(_ argv: [String]) throws -> ExitStatus {
    ///         Shell.bashCurrent.stdout("hello\n")
    ///         return .success
    ///     }
    /// }
    /// shell.register(GreetCommand())
    /// ```
    public func register(_ command: Command) {
        commands[command.name] = command
    }

    /// Register a closure-backed command — the shortest path to
    /// extending the shell. The closure reads shell state via
    /// ``Shell/current``.
    ///
    /// ```swift
    /// shell.register(name: "sum") { argv in
    ///     let total = argv.dropFirst().compactMap(Int.init).reduce(0, +)
    ///     Shell.bashCurrent.stdout("\(total)\n")
    ///     return .success
    /// }
    /// try shell.run("sum 1 2 3 4")   // → 10
    /// ```
    public func register(
        name: String,
        _ body: @Sendable @escaping ([String]) async throws -> ExitStatus
    ) {
        commands[name] = ClosureCommand(name: name, body: body)
    }

    /// Remove a command by name and return the removed entry (or
    /// `nil` if there was no such command).
    @discardableResult
    public func unregister(_ name: String) -> Command? {
        commands.removeValue(forKey: name)
    }

    /// If `path` is the canonical absolute path of a registered
    /// command (e.g. `/bin/bash`, `/usr/bin/env`, `/usr/local/bin/rg`),
    /// return the underlying `Command`. Used by the dispatcher so
    /// `/usr/bin/env bash --version` and the `#!/usr/bin/env bash`
    /// shebang resolve the same way as a bare `env` or `bash`
    /// invocation, instead of falling through as "command not found".
    /// Names without a matching catalog entry or no registration
    /// return `nil`.
    public func commandForCatalogPath(_ path: String) -> Command? {
        let basename = (path as NSString).lastPathComponent
        guard let canonical = BinCatalog.knownPaths[basename],
              canonical == path
        else { return nil }
        return commands[basename]
    }
}
