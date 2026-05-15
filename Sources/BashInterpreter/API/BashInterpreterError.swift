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

    /// A host OS failure (cd to a missing directory, etc.). `io` is the
    /// conventional acronym for input/output; public API.
    case io(String) // swiftlint:disable:this identifier_name

    /// A `${…}` parameter expansion failed — `${var:?msg}` on an unset
    /// variable, or a malformed body.
    case parameter(String)

    public var description: String {
        switch self {
        case .commandNotFound(let name):
            return "command not found: \(name)"
        case .invalidArguments(let builtin, let message):
            return "\(builtin): \(message)"
        case .unimplemented(let what):
            return "unimplemented: \(what)"
        case .io(let message):
            return message
        case .parameter(let message):
            return message
        }
    }
}
