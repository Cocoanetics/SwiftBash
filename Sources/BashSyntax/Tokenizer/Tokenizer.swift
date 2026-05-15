import Foundation

/// A streaming tokenizer for bash source.
///
/// The tokenizer is pull-driven: call ``nextToken()`` until it returns an
/// `.eof` token. It honours shell quoting, nested command/process/parameter
/// substitutions, and all of bash's redirection operators.
public final class Tokenizer {

    public let source: String
    let chars: [Character]
    var index: Int = 0

    // Rolling window of the last few tokens (for reserved-word / assignment detection).
    private var twoTokensAgo: Token?
    var tokenBeforeThat: Token?
    var lastReadToken: Token?

    // Delimiter stack for recursive matched-pair parsing.
    var delimiters: [Character] = []

    // Pending heredocs queued by redirections; processed on the next newline.
    struct PendingHeredoc {
        var delimiter: String
        var stripTabs: Bool
        var start: Int // position of the `<<` or `<<-` operator in source
        var bodyRange: Range<Int>?
        var body: String?
    }
    var pendingHeredocs: [PendingHeredoc] = []

    // Heredoc bodies indexed by the position of their originating operator.
    // The parser queries this to attach the body to the redirect node.
    var heredocBodies: [Int: (body: String, range: Range<Int>)] = [:]

    // After an IN or FOR/CASE reserved word, assignments aren't allowed.
    var inCasePat = false
    /// True inside `[[ … ]]` where extglob constructs are also allowed
    /// in patterns. Currently unused (the parser doesn't yet flip it),
    /// but referenced by ``readTokenWord`` so the wiring is in place
    /// for a future enhancement.
    var inExtglobPattern = false
    var openBraces = 0
    /// True when the leading word of the current command was one of
    /// bash's "assignment built-ins" — `declare`, `typeset`, `local`,
    /// `readonly`, `export`. While set, every subsequent argv element
    /// of that command is parsed with assignment-style tokenization so
    /// `declare -a a=(1 2 3)` recognizes `a=` as an assignment word and
    /// the parser folds the `(…)` items into an `arrayAssignment` node.
    /// Cleared at command boundaries (`;`, `\n`, `&&`, `||`, `|`, `&`,
    /// `(`, `)`, `{`, `}`, `;;`).
    var inDeclarationContext: Bool = false

    /// Words that, when they lead a command, switch the tokenizer
    /// into ``inDeclarationContext`` for the rest of that command.
    private static let assignmentBuiltins: Set<String> = [
        "declare", "typeset", "local", "readonly", "export"
    ]

    /// Tokens that close out a command and reset
    /// ``inDeclarationContext``. Subset of ``TokenType/commandStartTypes``
    /// — assignment-words and reserved keywords like `then`/`do` are
    /// *not* boundaries; they continue the current command (or
    /// introduce a follow-on body within a compound construct).
    private static let commandBoundaryTypes: Set<TokenType> = [
        .semicolon, .newline,
        .andAnd, .orOr, .bar, .barAnd, .ampersand,
        .semiSemi, .semiAnd, .semiSemiAnd,
        .leftParen, .rightParen, .leftCurly, .rightCurly
    ]

    public init(_ source: String) {
        self.source = source
        self.chars = Array(source)
    }

    // MARK: Character IO

    var eof: Bool { index >= chars.count }

    func peek(offset: Int = 0) -> Character? {
        let pos = index + offset
        return pos < chars.count ? chars[pos] : nil
    }

    func getc(removeQuotedNewline: Bool = true) -> Character? {
        while index < chars.count {
            let char = chars[index]
            index += 1
            if char == "\\",
               removeQuotedNewline,
               index < chars.count,
               chars[index] == "\n" {
                index += 1
                continue
            }
            return char
        }
        return nil
    }

    private func ungetc() {
        if index > 0 { index -= 1 }
    }

    // MARK: Token production

    /// Returns the next token in the stream; subsequent calls advance.
    public func nextToken() throws -> Token {
        let token = try readTokenInternal()
        // Update the assignment-built-in context BEFORE rotating the
        // history — we need to consult `lastReadToken` (still the
        // *previous* token) to know whether this one was emitted at
        // command position.
        let atCommandStart = lastReadToken.map {
            TokenType.commandStartTypes.contains($0.type)
        } ?? true
        if atCommandStart, token.type == .word,
           Self.assignmentBuiltins.contains(token.value) {
            inDeclarationContext = true
        } else if Self.commandBoundaryTypes.contains(token.type) {
            inDeclarationContext = false
        }
        // Track the last three tokens for reserved-word / assignment decisions.
        twoTokensAgo = tokenBeforeThat
        tokenBeforeThat = lastReadToken
        lastReadToken = token
        return token
    }

    /// Non-consuming peek at the next token. Subsequent peeks/nexts see the same token.
    private var lookahead: Token?

    public func peekToken() throws -> Token {
        if let cached = lookahead { return cached }
        let next = try nextToken()
        lookahead = next
        return next
    }

    public func consume() throws -> Token {
        if let cached = lookahead {
            lookahead = nil
            return cached
        }
        return try nextToken()
    }

    // MARK: - Core reader

    /// Advance past every `\<newline>` pair at the cursor. POSIX treats
    /// these as line continuations — they exist only at the lexical
    /// layer and never appear in tokens.
    private func skipLineContinuations() {
        while peek() == "\\", peek(offset: 1) == "\n" {
            index += 2
        }
    }

    private func readTokenInternal() throws -> Token {
        // Drop any line continuations at the cursor, then skip blanks.
        // Repeat: a continuation may sit between blanks (`\\<NL>` then
        // more spaces then another `\\<NL>`), and a blank may sit before
        // a continuation.
        while true {
            skipLineContinuations()
            if let char = peek(), SyntaxClass.isBlank(char) {
                _ = getc()
                continue
            }
            break
        }

        // comments: swallow until newline (but don't consume it)
        if peek() == "#" {
            while let char = peek(), char != "\n" {
                _ = getc()
            }
        }

        guard let char = peek() else {
            return Token(type: .eof, value: "", range: chars.count..<chars.count)
        }

        let start = index

        if char == "\n" {
            _ = getc()
            // gather any pending heredocs immediately after this newline
            try gatherPendingHeredocs()
            return Token(type: .newline, value: "\n", range: start..<start + 1)
        }

        if SyntaxClass.isMeta(char) {
            return try readMetaToken(startingAt: start)
        }

        // `-` after `<&` or `>&` stands alone as a DASH token
        if char == "-" {
            if let last = lastReadToken,
               last.type == .lessAnd || last.type == .greaterAnd {
                _ = getc()
                return Token(type: .dash, value: "-", range: start..<start + 1)
            }
        }

        return try readTokenWord()
    }

    // Meta/word readers + reserved-word/assignment heuristics live in
    // `Tokenizer+Reader.swift`; expansion / matched-pair helpers in
    // `Tokenizer+Parsing.swift`. Split keeps the class body within limits.

    /// Register a pending heredoc. The parser calls this after building a
    /// `<<` or `<<-` redirect so the body can be collected on the next newline.
    func registerHeredoc(delimiter: String, stripTabs: Bool, start: Int) {
        pendingHeredocs.append(
            PendingHeredoc(delimiter: delimiter, stripTabs: stripTabs,
                           start: start, bodyRange: nil, body: nil))
    }
}
