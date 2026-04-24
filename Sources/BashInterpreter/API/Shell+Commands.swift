import Foundation

extension Shell {

    /// Register a ``Command`` under its own `name`, replacing any existing
    /// entry for that name.
    ///
    /// ```swift
    /// struct GreetCommand: Command {
    ///     let name = "greet"
    ///     func run(_ argv: [String], shell: Shell) throws -> ExitStatus {
    ///         shell.stdout("hello\n")
    ///         return .success
    ///     }
    /// }
    /// shell.register(GreetCommand())
    /// ```
    public func register(_ command: Command) {
        commands[command.name] = command
    }

    /// Register a closure-backed command — the shortest path to extending
    /// the shell.
    ///
    /// ```swift
    /// shell.register(name: "sum") { argv, shell in
    ///     let total = argv.dropFirst().compactMap(Int.init).reduce(0, +)
    ///     shell.stdout("\(total)\n")
    ///     return .success
    /// }
    /// try shell.run("sum 1 2 3 4")   // → 10
    /// ```
    public func register(
        name: String,
        _ body: @Sendable @escaping ([String], Shell) async throws -> ExitStatus
    ) {
        commands[name] = ClosureCommand(name: name, body: body)
    }

    /// Remove a command by name and return the removed entry (or `nil` if
    /// there was no such command).
    @discardableResult
    public func unregister(_ name: String) -> Command? {
        commands.removeValue(forKey: name)
    }
}
