import Foundation

extension Node {

    /// A short lowercase name for this node's kind (`"list"`, `"command"`, …).
    public var kindName: String {
        switch kind {
        case .list: return "list"
        case .command: return "command"
        case .pipeline: return "pipeline"
        case .pipe: return "pipe"
        case .operator: return "operator"
        case .word: return "word"
        case .assignment: return "assignment"
        case .reservedWord: return "reservedword"
        case .redirect: return "redirect"
        case .commandSubstitution: return "commandsubstitution"
        case .processSubstitution: return "processsubstitution"
        case .parameter: return "parameter"
        case .tilde: return "tilde"
        case .heredoc: return "heredoc"
        case .compound: return "compound"
        case .ifCommand: return "if"
        case .whileCommand: return "while"
        case .untilCommand: return "until"
        case .forCommand: return "for"
        case .cStyleForCommand: return "cstylefor"
        case .caseCommand: return "case"
        case .pattern: return "pattern"
        case .function: return "function"
        case .arithmeticCommand: return "arithmeticcommand"
        case .arithmeticSubstitution: return "arithmeticsubstitution"
        case .conditional: return "conditional"
        case .arrayAssignment: return "arrayassignment"
        case .unimplemented: return "unimplemented"
        }
    }

    /// The immediate children of this node, in source order.
    ///
    /// Useful for generic traversals without pattern matching every case.
    public var children: [Node] {
        switch kind {
        case .list(let parts),
             .command(let parts),
             .pipeline(let parts),
             .word(_, let parts),
             .assignment(_, let parts),
             .ifCommand(let parts),
             .whileCommand(let parts),
             .untilCommand(let parts),
             .forCommand(let parts),
             .caseCommand(let parts),
             .pattern(let parts),
             .conditional(let parts),
             .unimplemented(let parts):
            return parts
        case .compound(let list, let redirects):
            return list + redirects
        case .redirect(_, _, let output, let heredoc):
            var result: [Node] = [output]
            if let heredoc { result.append(heredoc) }
            return result
        case .commandSubstitution(let command),
             .processSubstitution(let command):
            return [command]
        case .cStyleForCommand(_, _, _, let body):
            return [body]
        case .function(_, _, let parts):
            return parts
        case .arrayAssignment(_, let items, _):
            return items
        case .pipe, .operator, .reservedWord, .parameter, .tilde, .heredoc,
             .arithmeticCommand, .arithmeticSubstitution:
            return []
        }
    }

    /// The slice of the original source string covered by this node.
    public func source(from source: String) -> Substring {
        let chars = Array(source)
        let lo = max(0, range.lowerBound)
        let hi = min(chars.count, range.upperBound)
        guard lo < hi else { return "" }
        return Substring(String(chars[lo..<hi]))
    }
}
