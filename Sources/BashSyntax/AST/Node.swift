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

        /// A standalone `((expression))` arithmetic command. The expression
        /// body is stored verbatim; no sub-AST is produced for the math.
        case arithmeticCommand(String)

        /// A `$((expression))` arithmetic substitution occurring inside a
        /// word. The expression body is stored verbatim.
        case arithmeticSubstitution(String)

        /// `[[ EXPR ]]` — bash's enhanced conditional expression.
        /// `parts` is the flat token-by-token list (word nodes,
        /// operator nodes for `&&` / `||` / `<` / `>`, and
        /// `reservedWord("!" | "(" | ")")`) between the brackets.
        /// The interpreter decides how to fold it into a tree.
        case conditional(parts: [Node])

        /// `name=(item1 item2 …)` — indexed array assignment. `items`
        /// are word nodes; their expanded string values become the
        /// array elements at runtime. `append` is true for the
        /// `name+=(item …)` form, which extends an existing array
        /// instead of replacing it.
        case arrayAssignment(name: String, items: [Node], append: Bool)

        case unimplemented(parts: [Node])
    }
}
