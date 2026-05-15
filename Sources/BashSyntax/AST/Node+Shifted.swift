import Foundation

extension Node {
    // A copy of this subtree with every `range` shifted by `offset`.
    //
    // Used when splicing recursively-parsed substitution bodies back into
    // their enclosing source so node positions stay absolute.
    //
    // Exhaustive switch over Node.Kind; splitting per-case helpers would
    // scatter the dispatch without reducing real complexity.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func shifted(by offset: Int) -> Node {
        let newRange = (range.lowerBound + offset)..<(range.upperBound + offset)

        func shift(_ nodes: [Node]) -> [Node] { nodes.map { $0.shifted(by: offset) } }

        let newKind: Kind
        switch kind {
        case .list(let parts):
            newKind = .list(parts: shift(parts))
        case .command(let parts):
            newKind = .command(parts: shift(parts))
        case .pipeline(let parts):
            newKind = .pipeline(parts: shift(parts))
        case .pipe(let pipe):
            newKind = .pipe(pipe)
        case .operator(let symbol):
            newKind = .operator(symbol)
        case .word(let word, let parts):
            newKind = .word(word, parts: shift(parts))
        case .assignment(let word, let parts):
            newKind = .assignment(word, parts: shift(parts))
        case .reservedWord(let word):
            newKind = .reservedWord(word)
        case .redirect(let input, let type, let output, let heredoc):
            newKind = .redirect(input: input, type: type,
                                output: output.shifted(by: offset),
                                heredoc: heredoc?.shifted(by: offset))
        case .commandSubstitution(let cmd):
            newKind = .commandSubstitution(command: cmd.shifted(by: offset))
        case .processSubstitution(let cmd):
            newKind = .processSubstitution(command: cmd.shifted(by: offset))
        case .parameter(let value):
            newKind = .parameter(value)
        case .tilde(let value):
            newKind = .tilde(value)
        case .heredoc(let value):
            newKind = .heredoc(value)
        case .compound(let list, let redirects):
            newKind = .compound(list: shift(list), redirects: shift(redirects))
        case .ifCommand(let parts):
            newKind = .ifCommand(parts: shift(parts))
        case .whileCommand(let parts):
            newKind = .whileCommand(parts: shift(parts))
        case .untilCommand(let parts):
            newKind = .untilCommand(parts: shift(parts))
        case .forCommand(let parts):
            newKind = .forCommand(parts: shift(parts))
        case .cStyleForCommand(let initExpr, let condExpr, let updateExpr, let body):
            newKind = .cStyleForCommand(
                initExpr: initExpr, condExpr: condExpr, updateExpr: updateExpr,
                body: body.shifted(by: offset))
        case .caseCommand(let parts):
            newKind = .caseCommand(parts: shift(parts))
        case .pattern(let parts):
            newKind = .pattern(parts: shift(parts))
        case .function(let name, let body, let parts):
            newKind = .function(name: name.shifted(by: offset),
                                body: body.shifted(by: offset),
                                parts: shift(parts))
        case .arithmeticCommand(let expr):
            newKind = .arithmeticCommand(expr)
        case .arithmeticSubstitution(let expr):
            newKind = .arithmeticSubstitution(expr)
        case .conditional(let parts):
            newKind = .conditional(parts: shift(parts))
        case .arrayAssignment(let name, let items, let append):
            newKind = .arrayAssignment(
                name: name, items: shift(items), append: append)
        case .unimplemented(let parts):
            newKind = .unimplemented(parts: shift(parts))
        }
        return Node(kind: newKind, range: newRange)
    }
}
