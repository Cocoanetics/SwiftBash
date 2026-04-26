import Foundation

/// A command runnable from a ``Shell`` — both shipped built-ins and
/// user-registered extensions conform.
///
/// The shell looks up `argv[0]` in its command registry. If a matching
/// ``Command`` is found, its ``run(_:)`` is invoked; otherwise the
/// shell throws ``BashInterpreterError/commandNotFound(_:)``.
///
/// Implementations read shell state via ``Shell/current`` — a
/// `@TaskLocal` that the dispatcher sets to the executing shell
/// before invoking each command. So `Shell.current.stdout("hi\n")`,
/// `Shell.current.environment[…]`, etc. all just work.
///
/// Use ``Shell/register(_:)`` to add a struct-based command, or
/// ``Shell/register(name:_:)`` for a closure-backed one; see
/// ``ClosureCommand`` for the short-cut type.
public protocol Command: Sendable {
    /// Name by which this command is invoked (e.g. `"echo"`).
    var name: String { get }

    /// Execute the command.
    /// - Parameter argv: Full argument vector; `argv[0]` is the command
    ///   name and `argv[1...]` are its arguments.
    /// - Returns: The exit status to record as `$?`.
    ///
    /// The signature is `async` so commands can `await
    /// Shell.current.stdin.lines` or similar streaming APIs. Commands
    /// that don't await anything can still implement the method
    /// without any awaits inside — the `async` keyword is free if
    /// unused.
    func run(_ argv: [String]) async throws -> ExitStatus
}
