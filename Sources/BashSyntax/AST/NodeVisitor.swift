import Foundation

/// A visitor for traversing an AST produced by ``BashSyntax/parse(_:)``.
///
/// The default implementations do nothing, so callers only override the
/// methods they care about. Return `false` from a `visit…` method to skip
/// that node's children.
public protocol NodeVisitor {
    mutating func willVisit(_ node: Node) -> Bool
    mutating func didVisit(_ node: Node)

    mutating func visitList(_ node: Node, parts: [Node]) -> Bool
    mutating func visitCommand(_ node: Node, parts: [Node]) -> Bool
    mutating func visitPipeline(_ node: Node, parts: [Node]) -> Bool
    mutating func visitPipe(_ node: Node, pipe: String)
    mutating func visitOperator(_ node: Node, op: String)
    mutating func visitWord(_ node: Node, word: String, parts: [Node]) -> Bool
    mutating func visitAssignment(_ node: Node, word: String, parts: [Node]) -> Bool
    mutating func visitReservedWord(_ node: Node, word: String)
    mutating func visitRedirect(_ node: Node, input: Int?, type: String,
                                output: Node, heredoc: Node?) -> Bool
    mutating func visitCommandSubstitution(_ node: Node, command: Node) -> Bool
    mutating func visitProcessSubstitution(_ node: Node, command: Node) -> Bool
    mutating func visitParameter(_ node: Node, value: String)
    mutating func visitTilde(_ node: Node, value: String)
    mutating func visitHeredoc(_ node: Node, value: String)
    mutating func visitCompound(_ node: Node, list: [Node], redirects: [Node]) -> Bool
    mutating func visitIf(_ node: Node, parts: [Node]) -> Bool
    mutating func visitWhile(_ node: Node, parts: [Node]) -> Bool
    mutating func visitUntil(_ node: Node, parts: [Node]) -> Bool
    mutating func visitFor(_ node: Node, parts: [Node]) -> Bool
    mutating func visitCase(_ node: Node, parts: [Node]) -> Bool
    mutating func visitPattern(_ node: Node, parts: [Node]) -> Bool
    mutating func visitFunction(_ node: Node, name: Node, body: Node, parts: [Node]) -> Bool
    mutating func visitArithmeticCommand(_ node: Node, expression: String)
    mutating func visitArithmeticSubstitution(_ node: Node, expression: String)
    mutating func visitConditional(_ node: Node, parts: [Node]) -> Bool
    mutating func visitUnimplemented(_ node: Node, parts: [Node]) -> Bool
}
