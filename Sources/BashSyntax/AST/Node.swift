import Foundation

/// A node in the bash AST produced by ``BashSyntax/parse(_:)``.
///
/// `Node` is a tagged sum: ``Kind`` enumerates every variant,
/// and `range` records the span of source characters the node covers.
public struct Node: Hashable, Sendable {

    /// The kind of node, carrying the kind-specific children.
    public let kind: Kind

    /// Character offsets in the original source string (`start..<end`).
    public let range: Range<Int>

    public init(kind: Kind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }

    /// The variants of a bash AST node.
    public indirect enum Kind: Hashable, Sendable {
        case list(parts: [Node])
        case command(parts: [Node])
        case pipeline(parts: [Node])
        case pipe(String)
        case `operator`(String)
        case word(String, parts: [Node])
        case assignment(String, parts: [Node])
        case reservedWord(String)
        case redirect(input: Int?, type: String, output: Node, heredoc: Node?)
        case commandSubstitution(command: Node)
        case processSubstitution(command: Node)
        case parameter(String)
        case tilde(String)
        case heredoc(String)
        case compound(list: [Node], redirects: [Node])
        case ifCommand(parts: [Node])
        case whileCommand(parts: [Node])
        case untilCommand(parts: [Node])
        case forCommand(parts: [Node])
        case caseCommand(parts: [Node])
        case pattern(parts: [Node])
        case function(name: Node, body: Node, parts: [Node])
        case unimplemented(parts: [Node])
    }
}
