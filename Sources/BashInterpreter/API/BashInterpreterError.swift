import Foundation

/// Errors raised while executing a bash AST.
public enum BashInterpreterError: Error, Equatable, Sendable, CustomStringConvertible {

    /// No builtin with this name is registered (and external-process
    /// execution isn't implemented yet in this skeleton).
    case commandNotFound(String)

    /// A built-in was invoked with invalid arguments.
    case invalidArguments(builtin: String, message: String)

    /// A feature (external exec, pipelines, arithmetic evaluation, …) is
    /// recognised by the parser but not yet handled by the interpreter.
    case unimplemented(String)

    /// A host OS failure (cd to a missing directory, etc.).
    case io(String)

    /// A `${…}` parameter expansion failed — `${var:?msg}` on an unset
    /// variable, or a malformed body.
    case parameter(String)

    public var description: String {
        switch self {
        case .commandNotFound(let name):
            return "command not found: \(name)"
        case .invalidArguments(let b, let m):
            return "\(b): \(m)"
        case .unimplemented(let what):
            return "unimplemented: \(what)"
        case .io(let m):
            return m
        case .parameter(let m):
            return m
        }
    }
}
