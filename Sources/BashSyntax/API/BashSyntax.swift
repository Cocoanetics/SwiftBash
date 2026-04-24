import Foundation

/// The top-level namespace for the `BashSyntax` library — a modern Swift
/// implementation of a bash syntax parser.
///
/// ```swift
/// let parts = try BashSyntax.parse("true && cat <(echo $(echo foo))")
/// for ast in parts {
///     print(ast.dump())
/// }
/// ```
public enum BashSyntax {

    /// Parse a bash source string and return an array of top-level AST nodes.
    ///
    /// - Parameter source: The bash source to parse.
    /// - Returns: An array of ``Node``s, one per top-level command/list/pipeline.
    /// - Throws: ``BashSyntaxError/parsing(message:source:position:)`` on syntax errors.
    public static func parse(_ source: String) throws -> [Node] {
        let parser = Parser(source)
        return try parser.parseAll()
    }

    /// Parse a bash source string, returning only the first top-level unit.
    ///
    /// Useful when you know the input is one command but are fine with trailing
    /// text being ignored.
    public static func parseSingle(_ source: String) throws -> Node {
        let parser = Parser(source)
        return try parser.parseFirst()
    }

    /// Tokenise a bash source string, returning the expanded word values and
    /// raw operator spelling — a strict superset of `shlex.split` that
    /// understands command and process substitutions.
    ///
    /// ```swift
    /// try BashSyntax.split(#"cat <(echo "a $(echo b)") | tee"#)
    /// // => ["cat", "<(echo \"a $(echo b)\")", "|", "tee"]
    /// ```
    public static func split(_ source: String) throws -> [String] {
        let tokenizer = Tokenizer(source)
        var out: [String] = []
        let expander = WordExpander { body, baseOffset in
            // We only need expanded text for `split`, not a real AST, but the
            // expander still calls us for recursive bodies. Return a stub.
            return Node(kind: .command(parts: []),
                        range: baseOffset..<(baseOffset + body.count))
        }
        while true {
            let t = try tokenizer.nextToken()
            if t.type == .eof { break }
            if t.type == .newline {
                out.append("\n")
                continue
            }
            if t.type == .word || t.type == .assignmentWord {
                let r = try expander.expand(token: t)
                out.append(r.expanded)
            } else {
                out.append(t.value)
            }
        }
        return out
    }
}
