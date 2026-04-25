import Foundation

extension Node {
    /// A copy of this subtree with every `range` shifted by `offset`.
    ///
    /// Used when splicing recursively-parsed substitution bodies back into
    /// their enclosing source so node positions stay absolute.
    func shifted(by offset: Int) -> Node {
        let newRange = (range.lowerBound + offset)..<(range.upperBound + offset)

        func shift(_ ns: [Node]) -> [Node] { ns.map { $0.shifted(by: offset) } }

        let newKind: Kind
        switch kind {
        case .list(let parts):
            newKind = .list(parts: shift(parts))
        case .command(let parts):
            newKind = .command(parts: shift(parts))
        case .pipeline(let parts):
            newKind = .pipeline(parts: shift(parts))
        case .pipe(let p):
            newKind = .pipe(p)
        case .operator(let op):
            newKind = .operator(op)
        case .word(let w, let parts):
            newKind = .word(w, parts: shift(parts))
        case .assignment(let w, let parts):
            newKind = .assignment(w, parts: shift(parts))
        case .reservedWord(let w):
            newKind = .reservedWord(w)
        case .redirect(let input, let type, let output, let heredoc):
            newKind = .redirect(input: input, type: type,
                                output: output.shifted(by: offset),
                                heredoc: heredoc?.shifted(by: offset))
        case .commandSubstitution(let c):
            newKind = .commandSubstitution(command: c.shifted(by: offset))
        case .processSubstitution(let c):
            newKind = .processSubstitution(command: c.shifted(by: offset))
        case .parameter(let v):
            newKind = .parameter(v)
        case .tilde(let v):
            newKind = .tilde(v)
        case .heredoc(let v):
            newKind = .heredoc(v)
        case .compound(let list, let redirects):
            newKind = .compound(list: shift(list), redirects: shift(redirects))
        case .ifCommand(let p):    newKind = .ifCommand(parts: shift(p))
        case .whileCommand(let p): newKind = .whileCommand(parts: shift(p))
        case .untilCommand(let p): newKind = .untilCommand(parts: shift(p))
        case .forCommand(let p):   newKind = .forCommand(parts: shift(p))
        case .cStyleForCommand(let i, let c, let u, let body):
            newKind = .cStyleForCommand(
                initExpr: i, condExpr: c, updateExpr: u,
                body: body.shifted(by: offset))
        case .caseCommand(let p):  newKind = .caseCommand(parts: shift(p))
        case .pattern(let p):      newKind = .pattern(parts: shift(p))
        case .function(let name, let body, let parts):
            newKind = .function(name: name.shifted(by: offset),
                                body: body.shifted(by: offset),
                                parts: shift(parts))
        case .arithmeticCommand(let e):
            newKind = .arithmeticCommand(e)
        case .arithmeticSubstitution(let e):
            newKind = .arithmeticSubstitution(e)
        case .conditional(let p):
            newKind = .conditional(parts: shift(p))
        case .arrayAssignment(let name, let items, let append):
            newKind = .arrayAssignment(
                name: name, items: shift(items), append: append)
        case .unimplemented(let p):
            newKind = .unimplemented(parts: shift(p))
        }
        return Node(kind: newKind, range: newRange)
    }
}
