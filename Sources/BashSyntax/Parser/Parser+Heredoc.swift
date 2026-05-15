import Foundation

extension Parser {

    /// Walk `node` and attach heredoc bodies gathered by the tokenizer to
    /// any `<<` / `<<-` redirect nodes whose start position matches.
    func attachHeredocBodies(_ node: Node) -> Node {
        let bodies = tokenizer.heredocBodies
        if bodies.isEmpty { return node }
        return rewriteHeredoc(node, bodies: bodies)
    }

    // Recursive `Node.Kind` rewriter: when a heredoc redirect with a
    // matching start position is found, splice the body in; otherwise
    // map children recursively. Exhaustive switch over Kind cases.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func rewriteHeredoc(_ current: Node,
                                bodies: [Int: (body: String, range: Range<Int>)]) -> Node {
        func rewrite(_ inner: Node) -> Node { rewriteHeredoc(inner, bodies: bodies) }
        switch current.kind {
        case .redirect(let input, let type, let output, let heredoc)
            where (type == "<<" || type == "<<-") && heredoc == nil:
            if let body = bodies[current.range.lowerBound] {
                let heredocNode = Node(kind: .heredoc(body.body),
                                       range: body.range)
                let newRange = current.range.lowerBound..<max(current.range.upperBound,
                                                              body.range.upperBound)
                return Node(
                    kind: .redirect(input: input, type: type,
                                    output: rewrite(output),
                                    heredoc: heredocNode),
                    range: newRange)
            }
            return current
        case .list(let parts):
            return Node(kind: .list(parts: parts.map(rewrite)), range: current.range)
        case .command(let parts):
            return Node(kind: .command(parts: parts.map(rewrite)), range: current.range)
        case .pipeline(let parts):
            return Node(kind: .pipeline(parts: parts.map(rewrite)), range: current.range)
        case .compound(let list, let redirects):
            return Node(
                kind: .compound(list: list.map(rewrite),
                                redirects: redirects.map(rewrite)),
                range: current.range)
        case .word(let word, let parts):
            return Node(kind: .word(word, parts: parts.map(rewrite)), range: current.range)
        case .assignment(let word, let parts):
            return Node(kind: .assignment(word, parts: parts.map(rewrite)),
                        range: current.range)
        case .redirect(let input, let type, let output, let heredoc):
            return Node(
                kind: .redirect(input: input, type: type,
                                output: rewrite(output),
                                heredoc: heredoc.map(rewrite)),
                range: current.range)
        case .commandSubstitution(let cmd):
            return Node(kind: .commandSubstitution(command: rewrite(cmd)),
                        range: current.range)
        case .processSubstitution(let cmd):
            return Node(kind: .processSubstitution(command: rewrite(cmd)),
                        range: current.range)
        case .ifCommand(let parts):
            return Node(kind: .ifCommand(parts: parts.map(rewrite)), range: current.range)
        case .whileCommand(let parts):
            return Node(kind: .whileCommand(parts: parts.map(rewrite)), range: current.range)
        case .untilCommand(let parts):
            return Node(kind: .untilCommand(parts: parts.map(rewrite)), range: current.range)
        case .forCommand(let parts):
            return Node(kind: .forCommand(parts: parts.map(rewrite)), range: current.range)
        case .cStyleForCommand(let initExpr, let condExpr, let updateExpr, let body):
            return Node(
                kind: .cStyleForCommand(initExpr: initExpr, condExpr: condExpr,
                                        updateExpr: updateExpr, body: rewrite(body)),
                range: current.range)
        case .caseCommand(let parts):
            return Node(kind: .caseCommand(parts: parts.map(rewrite)), range: current.range)
        case .pattern(let parts):
            return Node(kind: .pattern(parts: parts.map(rewrite)), range: current.range)
        case .function(let name, let body, let parts):
            return Node(
                kind: .function(name: rewrite(name), body: rewrite(body),
                                parts: parts.map(rewrite)),
                range: current.range)
        case .unimplemented(let parts):
            return Node(kind: .unimplemented(parts: parts.map(rewrite)), range: current.range)
        default:
            return current
        }
    }
}
