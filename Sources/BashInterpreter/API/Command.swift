import Foundation

/// A command runnable from a ``Shell`` — both shipped built-ins and
/// user-registered extensions conform.
///
/// The shell looks up `argv[0]` in its command registry. If a matching
/// ``Command`` is found, its ``run(_:shell:)`` is invoked; otherwise the
/// shell throws ``BashInterpreterError/commandNotFound(_:)``.
///
/// Use ``Shell/register(_:)`` to add a struct-based command, or
/// ``Shell/register(name:_:)`` for a closure-backed one; see
/// ``ClosureCommand`` for the short-cut type.
public protocol Command {
    /// Name by which this command is invoked (e.g. `"echo"`).
    var name: String { get }

    /// Execute the command.
    /// - Parameter argv: Full argument vector; `argv[0]` is the command
    ///   name and `argv[1...]` are its arguments.
    /// - Parameter shell: The invoking shell; commands read and mutate
    ///   its `environment` and write to `stdout` / `stderr`.
    /// - Returns: The exit status to record as `$?`.
    func run(_ argv: [String], shell: Shell) throws -> ExitStatus
}
