import Foundation

/// Errors raised by the bash parser.
public enum BashSyntaxError: Error, Equatable, Sendable, CustomStringConvertible {

    /// A syntactic problem was detected while tokenising or parsing.
    /// - message: Human-readable description.
    /// - source: The input that failed to parse.
    /// - position: Zero-based character offset where the error was detected.
    case parsing(message: String, source: String, position: Int)

    /// A feature of bash is known but not yet implemented.
    case unimplemented(String)

    public var description: String {
        switch self {
        case .parsing(let msg, _, let pos):
            return "\(msg) (position \(pos))"
        case .unimplemented(let what):
            return "unimplemented: \(what)"
        }
    }

    /// Convenience accessor for the human-readable message.
    public var message: String {
        if case .parsing(let msg, _, _) = self { return msg }
        if case .unimplemented(let msg) = self { return msg }
        return description
    }

    /// Convenience accessor for the offending source (parsing errors only).
    public var source: String? {
        if case .parsing(_, let src, _) = self { return src }
        return nil
    }

    /// Convenience accessor for the error offset (parsing errors only).
    public var position: Int? {
        if case .parsing(_, _, let pos) = self { return pos }
        return nil
    }
}
