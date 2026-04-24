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
        if case .parsing(let m, _, _) = self { return m }
        if case .unimplemented(let m) = self { return m }
        return description
    }

    /// Convenience accessor for the offending source (parsing errors only).
    public var source: String? {
        if case .parsing(_, let s, _) = self { return s }
        return nil
    }

    /// Convenience accessor for the error offset (parsing errors only).
    public var position: Int? {
        if case .parsing(_, _, let p) = self { return p }
        return nil
    }
}
