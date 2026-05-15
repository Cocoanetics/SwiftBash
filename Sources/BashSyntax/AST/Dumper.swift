import Foundation

/// Pretty-prints a ``Node`` subtree into a stable, reader-friendly form.
///
/// Instantiated by ``Node/dump(indent:source:)``; not part of the public
/// surface.
struct Dumper {
    let indent: String
    let source: [Character]?

    init(indent: String, source: String?) {
        self.indent = indent
        self.source = source.map(Array.init)
    }

    enum FieldValue {
        case scalar(String)     // inline, already rendered
        case node(Node)
        case nodeList([Node])

        var isEmpty: Bool {
            switch self {
            case .scalar(let str): return str.isEmpty
            case .node: return false
            case .nodeList(let nodes): return nodes.isEmpty
            }
        }
    }

    struct Field {
        let name: String
        let value: FieldValue
    }

    // MARK: Top-level render

    func format(_ node: Node, level: Int) -> String {
        // When a list node is nested inside another container the contained
        // list is rendered with extra indentation for readability.
        var effectiveLevel = level
        if case .list = node.kind, level > 0 {
            effectiveLevel = level + 1
        }

        let fields = orderedFields(for: node, at: effectiveLevel)

        let rendered = fields.map { field -> String in
            "\(field.name)=\(renderValue(field.value, at: effectiveLevel))"
        }.joined(separator: ", ")

        let title = titleCase(node.kindName)
        return "\(title)Node(\(rendered))"
    }

    private func renderValue(_ value: FieldValue, at level: Int) -> String {
        switch value {
        case .scalar(let str):
            return str
        case .node(let node):
            // Nodes are prefixed with newline + indent one deeper.
            let deeper = level + 1
            return "\n" + String(repeating: indent, count: deeper)
                 + format(node, level: deeper)
        case .nodeList(let nodes):
            return renderList(nodes, at: level)
        }
    }

    private func renderList(_ nodes: [Node], at level: Int) -> String {
        if nodes.isEmpty { return "[]" }
        let inner = String(repeating: indent, count: level + 1)
        let outer = String(repeating: indent, count: level)
        var lines = ["["]
        for node in nodes {
            lines.append("\(inner)\(format(node, level: level + 1)),")
        }
        lines.append("\(outer)]")
        return lines.joined(separator: "\n")
    }

    // MARK: Field ordering

    /// Field order for `dump()`: `s` first (when positions were converted),
    /// then alphabetically sorted non-`parts` fields, then `parts` last.
    private func orderedFields(for node: Node, at level: Int) -> [Field] {
        var all = rawFields(for: node)

        // `function` nodes drop the name/body fields — they appear inside parts.
        if case .function = node.kind {
            all.removeAll { $0.name == "name" || $0.name == "body" }
        }

        // Convert pos → s if a source string was supplied.
        if source != nil {
            all = all.map { field in
                if field.name == "pos",
                   case .scalar = field.value {
                    return Field(name: "s", value: .scalar(sliceRepr(node.range)))
                }
                return field
            }
        }

        // Drop empty optional fields.
        all = all.filter { !$0.value.isEmpty }

        // Split out "s" (goes first) and "parts" (goes last).
        var first: [Field] = []
        var middle: [Field] = []
        var last: [Field] = []
        for field in all {
            if field.name == "s" {
                first.append(field)
            } else if field.name == "parts" {
                last.append(field)
            } else {
                middle.append(field)
            }
        }
        middle.sort { $0.name < $1.name }

        return first + middle + last
    }

    // MARK: Raw field extraction

    // swiftlint:disable:next cyclomatic_complexity function_body_length - large case dispatch over many node kinds
    private func rawFields(for node: Node) -> [Field] {
        let posField = Field(name: "pos", value: .scalar(posRepr(node.range)))

        switch node.kind {
        case .list(let parts),
             .command(let parts),
             .pipeline(let parts),
             .ifCommand(let parts),
             .whileCommand(let parts),
             .untilCommand(let parts),
             .forCommand(let parts),
             .caseCommand(let parts),
             .pattern(let parts),
             .conditional(let parts),
             .unimplemented(let parts):
            return [posField, Field(name: "parts", value: .nodeList(parts))]

        case .word(let word, let parts),
             .assignment(let word, let parts):
            return [
                posField,
                Field(name: "word", value: .scalar(stringRepr(word))),
                Field(name: "parts", value: .nodeList(parts))
            ]

        case .arrayAssignment(let name, let items, let append):
            return [
                posField,
                Field(name: "name", value: .scalar(stringRepr(name))),
                Field(name: "items", value: .nodeList(items)),
                Field(name: "append", value: .scalar(append ? "true" : "false"))
            ]

        case .reservedWord(let word):
            return [
                posField,
                Field(name: "word", value: .scalar(stringRepr(word)))
            ]

        case .pipe(let pipe):
            return [
                Field(name: "pipe", value: .scalar(stringRepr(pipe))),
                posField
            ]

        case .operator(let oper):
            return [
                Field(name: "op", value: .scalar(stringRepr(oper))),
                posField
            ]

        case .parameter(let value),
             .tilde(let value),
             .heredoc(let value):
            return [
                posField,
                Field(name: "value", value: .scalar(stringRepr(value)))
            ]

        case .redirect(let input, let type, let output, let heredoc):
            var fields: [Field] = []
            if let heredoc {
                fields.append(Field(name: "heredoc", value: .node(heredoc)))
            }
            if let input {
                fields.append(Field(name: "input", value: .scalar("\(input)")))
            }
            fields.append(Field(name: "output", value: .node(output)))
            fields.append(posField)
            fields.append(Field(name: "type", value: .scalar(stringRepr(type))))
            return fields

        case .commandSubstitution(let command),
             .processSubstitution(let command):
            return [
                Field(name: "command", value: .node(command)),
                posField
            ]

        case .compound(let list, let redirects):
            return [
                Field(name: "list", value: .nodeList(list)),
                posField,
                Field(name: "redirects", value: .nodeList(redirects))
            ]

        case .function(let name, let body, let parts):
            return [
                Field(name: "body", value: .node(body)),
                Field(name: "name", value: .node(name)),
                posField,
                Field(name: "parts", value: .nodeList(parts))
            ]

        case .arithmeticCommand(let expr),
             .arithmeticSubstitution(let expr):
            return [
                Field(name: "expression", value: .scalar(stringRepr(expr))),
                posField
            ]

        case .cStyleForCommand(let initExpr, let condExpr, let updateExpr, let body):
            return [
                Field(name: "init", value: .scalar(stringRepr(initExpr))),
                Field(name: "cond", value: .scalar(stringRepr(condExpr))),
                Field(name: "update", value: .scalar(stringRepr(updateExpr))),
                Field(name: "body", value: .node(body)),
                posField
            ]
        }
    }

    // MARK: Primitive rendering

    private func posRepr(_ range: Range<Int>) -> String {
        "(\(range.lowerBound), \(range.upperBound))"
    }

    private func sliceRepr(_ range: Range<Int>) -> String {
        guard let chars = source else { return stringRepr("") }
        let low = max(0, min(chars.count, range.lowerBound))
        let high = max(low, min(chars.count, range.upperBound))
        return stringRepr(String(chars[low..<high]))
    }

    private func stringRepr(_ str: String) -> String {
        // Python-style `repr` of a string, defaulting to single quotes and
        // falling back to double quotes if the value contains a single quote
        // but no double quote.
        let hasSingle = str.contains("'")
        let hasDouble = str.contains("\"")
        let useDouble = hasSingle && !hasDouble
        let quote: Character = useDouble ? "\"" : "'"

        var out = String()
        out.reserveCapacity(str.count + 2)
        out.append(quote)
        for char in str {
            switch char {
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case quote: out.append("\\"); out.append(char)
            default:
                if char.asciiValue.map({ $0 < 0x20 || $0 == 0x7F }) == true {
                    let ascii = Int(char.asciiValue!)
                    out.append(String(format: "\\x%02x", ascii))
                } else {
                    out.append(char)
                }
            }
        }
        out.append(quote)
        return out
    }

    private func titleCase(_ str: String) -> String {
        guard let first = str.first else { return str }
        return String(first).uppercased() + str.dropFirst()
    }
}
