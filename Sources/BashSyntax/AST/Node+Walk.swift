import Foundation

extension Node {
    /// Walk this subtree, calling the appropriate `visit*` method on `visitor`.
    public func walk<V: NodeVisitor>(_ visitor: inout V) {
        guard visitor.willVisit(self) else { return }

        let descend: Bool
        switch kind {
        case .list(let parts):
            descend = visitor.visitList(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .command(let parts):
            descend = visitor.visitCommand(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .pipeline(let parts):
            descend = visitor.visitPipeline(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .pipe(let pipe):
            visitor.visitPipe(self, pipe: pipe)
        case .operator(let op):
            visitor.visitOperator(self, op: op)
        case .word(let word, let parts):
            descend = visitor.visitWord(self, word: word, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .assignment(let word, let parts):
            descend = visitor.visitAssignment(self, word: word, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .reservedWord(let word):
            visitor.visitReservedWord(self, word: word)
        case .redirect(let input, let type, let output, let heredoc):
            descend = visitor.visitRedirect(self, input: input, type: type,
                                            output: output, heredoc: heredoc)
            if descend {
                output.walk(&visitor)
                heredoc?.walk(&visitor)
            }
        case .commandSubstitution(let command):
            descend = visitor.visitCommandSubstitution(self, command: command)
            if descend { command.walk(&visitor) }
        case .processSubstitution(let command):
            descend = visitor.visitProcessSubstitution(self, command: command)
            if descend { command.walk(&visitor) }
        case .parameter(let value):
            visitor.visitParameter(self, value: value)
        case .tilde(let value):
            visitor.visitTilde(self, value: value)
        case .heredoc(let value):
            visitor.visitHeredoc(self, value: value)
        case .compound(let list, let redirects):
            descend = visitor.visitCompound(self, list: list, redirects: redirects)
            if descend {
                list.forEach { $0.walk(&visitor) }
                redirects.forEach { $0.walk(&visitor) }
            }
        case .ifCommand(let parts):
            descend = visitor.visitIf(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .whileCommand(let parts):
            descend = visitor.visitWhile(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .untilCommand(let parts):
            descend = visitor.visitUntil(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .forCommand(let parts):
            descend = visitor.visitFor(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .caseCommand(let parts):
            descend = visitor.visitCase(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .pattern(let parts):
            descend = visitor.visitPattern(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .function(let name, let body, let parts):
            descend = visitor.visitFunction(self, name: name, body: body, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .arithmeticCommand(let expr):
            visitor.visitArithmeticCommand(self, expression: expr)
        case .arithmeticSubstitution(let expr):
            visitor.visitArithmeticSubstitution(self, expression: expr)
        case .conditional(let parts):
            descend = visitor.visitConditional(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        case .arrayAssignment(let name, let items):
            descend = visitor.visitArrayAssignment(self, name: name, items: items)
            if descend { items.forEach { $0.walk(&visitor) } }
        case .unimplemented(let parts):
            descend = visitor.visitUnimplemented(self, parts: parts)
            if descend { parts.forEach { $0.walk(&visitor) } }
        }

        visitor.didVisit(self)
    }
}
