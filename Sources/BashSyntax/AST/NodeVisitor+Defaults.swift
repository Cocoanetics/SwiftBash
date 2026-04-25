import Foundation

extension NodeVisitor {
    public mutating func willVisit(_ node: Node) -> Bool { true }
    public mutating func didVisit(_ node: Node) {}

    public mutating func visitList(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitCommand(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitPipeline(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitPipe(_ node: Node, pipe: String) {}
    public mutating func visitOperator(_ node: Node, op: String) {}
    public mutating func visitWord(_ node: Node, word: String, parts: [Node]) -> Bool { true }
    public mutating func visitAssignment(_ node: Node, word: String, parts: [Node]) -> Bool { true }
    public mutating func visitReservedWord(_ node: Node, word: String) {}
    public mutating func visitRedirect(_ node: Node, input: Int?, type: String,
                                       output: Node, heredoc: Node?) -> Bool { true }
    public mutating func visitCommandSubstitution(_ node: Node, command: Node) -> Bool { true }
    public mutating func visitProcessSubstitution(_ node: Node, command: Node) -> Bool { true }
    public mutating func visitParameter(_ node: Node, value: String) {}
    public mutating func visitTilde(_ node: Node, value: String) {}
    public mutating func visitHeredoc(_ node: Node, value: String) {}
    public mutating func visitCompound(_ node: Node, list: [Node], redirects: [Node]) -> Bool { true }
    public mutating func visitIf(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitWhile(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitUntil(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitFor(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitCase(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitPattern(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitFunction(_ node: Node, name: Node, body: Node, parts: [Node]) -> Bool { true }
    public mutating func visitArithmeticCommand(_ node: Node, expression: String) {}
    public mutating func visitArithmeticSubstitution(_ node: Node, expression: String) {}
    public mutating func visitConditional(_ node: Node, parts: [Node]) -> Bool { true }
    public mutating func visitArrayAssignment(_ node: Node, name: String, items: [Node], append: Bool) -> Bool { true }
    public mutating func visitUnimplemented(_ node: Node, parts: [Node]) -> Bool { true }
}
