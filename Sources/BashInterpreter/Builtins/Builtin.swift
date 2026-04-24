import Foundation

/// A shell built-in. Each built-in owns a `name` and a `run` function.
/// The shell looks up the argv's first element in its builtin registry.
public protocol Builtin: Sendable {
    /// Name by which this built-in is invoked (e.g. `"echo"`).
    var name: String { get }

    /// Execute the built-in.
    /// - Parameter argv: Full argument vector; `argv[0]` is the command name
    ///   and `argv[1...]` are its arguments.
    /// - Parameter shell: The invoking shell; built-ins read and mutate its
    ///   `environment` and write to `stdout` / `stderr`.
    /// - Returns: The exit status to record.
    func run(_ argv: [String], shell: Shell) throws -> ExitStatus
}
