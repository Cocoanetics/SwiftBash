import Foundation

/// A recursive-descent parser over the token stream produced by ``Tokenizer``.
///
/// ``Parser`` is instantiated internally by the public API (``BashSyntax.parse``,
/// ``BashSyntax.parseSingle``) — you usually don't need to touch it directly.
public final class Parser {

    public let source: String
    let tokenizer: Tokenizer
    let expansionLimit: Int
    let proceedOnError: Bool

    /// Buffered tokens (for multi-token lookahead).
    var buffer: [Token] = []
    /// A tokenizer error that occurred during lookahead, surfaced on the next `consume`.
    var pendingTokenizerError: Error?

    /// Track the depth of substitution parsing so we can cap runaway recursion.
    let depth: Int

    public convenience init(_ source: String,
                            expansionLimit: Int = 200,
                            proceedOnError: Bool = false) {
        self.init(source: source, tokenizer: Tokenizer(source),
                  expansionLimit: expansionLimit,
                  proceedOnError: proceedOnError, depth: 0)
    }

    init(source: String, tokenizer: Tokenizer,
         expansionLimit: Int, proceedOnError: Bool, depth: Int) {
        self.source = source
        self.tokenizer = tokenizer
        self.expansionLimit = expansionLimit
        self.proceedOnError = proceedOnError
        self.depth = depth
    }

    // MARK: - Public entry points

    /// Parse the full source. May return multiple top-level parts for
    /// multi-line input.
    public func parseAll() throws -> [Node] {
        var parts: [Node] = []
        while true {
            while peek().type == .newline { _ = try next() }
            try surfaceTokenizerError()
            if peek().type == .eof { break }
            let node = try parseSimpleList()
            parts.append(node)
            // After a simple_list, optionally consume terminators.
            while peek().type == .newline { _ = try next() }
        }
        try surfaceTokenizerError()
        return parts.map { attachHeredocBodies($0) }
    }

    /// Parse only the first top-level unit.
    public func parseFirst() throws -> Node {
        while peek().type == .newline { _ = try next() }
        try surfaceTokenizerError()
        if peek().type == .eof {
            throw BashSyntaxError.parsing(message: "unexpected EOF",
                                       source: source,
                                       position: source.count)
        }
        let node = try parseSimpleList()
        try surfaceTokenizerError()
        return attachHeredocBodies(node)
    }

    func surfaceTokenizerError() throws {
        if let err = pendingTokenizerError {
            pendingTokenizerError = nil
            throw err
        }
    }

    // MARK: - Token plumbing

    func peek(offset: Int = 0) -> Token {
        while buffer.count <= offset {
            do {
                buffer.append(try tokenizer.nextToken())
            } catch {
                // Record and return EOF so callers can decide; throwing here
                // would force every peek to be `try`. try next() surfaces the error
                // on the next non-buffered read.
                pendingTokenizerError = error
                buffer.append(Token(type: .eof, value: "",
                                    range: source.count..<source.count))
            }
        }
        return buffer[offset]
    }

    @discardableResult
    func next() throws -> Token {
        if buffer.isEmpty {
            return try tokenizer.nextToken()
        }
        let token = buffer.removeFirst()
        if buffer.isEmpty, let err = pendingTokenizerError {
            // The buffer we just drained was synthesized after a tokenizer
            // error — surface that error now.
            pendingTokenizerError = nil
            if token.type == .eof { throw err }
        }
        return token
    }

    func expect(_ type: TokenType, _ description: String) throws -> Token {
        let token = peek()
        guard token.type == type else {
            throw BashSyntaxError.parsing(
                message: "expected \(description), found \(token.value.isEmpty ? "EOF" : token.value)",
                source: source,
                position: token.range.lowerBound)
        }
        return try next()
    }

    // MARK: - Word expansion

    func expandWord(_ token: Token, asAssignment: Bool) throws -> Node {
        let expander = WordExpander { [weak self] body, baseOffset in
            guard let self else {
                return Node(kind: .command(parts: []),
                            range: baseOffset..<baseOffset)
            }
            return try self.parseSub(body: body, baseOffset: baseOffset)
        }

        let result = try expander.expand(token: token)
        let kind: Node.Kind = asAssignment
            ? .assignment(result.expanded, parts: result.parts)
            : .word(result.expanded, parts: result.parts)
        return Node(kind: kind, range: token.range)
    }

    /// Parse a substring as a bash command, adjusting positions to absolute.
    func parseSub(body: String, baseOffset: Int) throws -> Node {
        guard depth < expansionLimit else {
            return Node(kind: .command(parts: []),
                        range: baseOffset..<(baseOffset + body.count))
        }
        let sub = Parser(source: body, tokenizer: Tokenizer(body),
                         expansionLimit: expansionLimit,
                         proceedOnError: proceedOnError, depth: depth + 1)
        let node = try sub.parseFirst()
        return node.shifted(by: baseOffset)
    }

    // MARK: - Utility

    func spanOf(_ parts: [Node]) -> Range<Int> {
        guard let first = parts.first, let last = parts.last else { return 0..<0 }
        return first.range.lowerBound..<last.range.upperBound
    }
}
