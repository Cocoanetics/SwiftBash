import Foundation

/// A streaming tokenizer for bash source.
///
/// The tokenizer is pull-driven: call ``nextToken()`` until it returns an
/// `.eof` token. It honours shell quoting, nested command/process/parameter
/// substitutions, and all of bash's redirection operators.
public final class Tokenizer {

    public let source: String
    private let chars: [Character]
    private var index: Int = 0

    // Rolling window of the last few tokens (for reserved-word / assignment detection).
    private var twoTokensAgo: Token?
    private var tokenBeforeThat: Token?
    private var lastReadToken: Token?

    // Delimiter stack for recursive matched-pair parsing.
    private var delimiters: [Character] = []

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
    private var inCasePat = false
    private var openBraces = 0

    public init(_ source: String) {
        self.source = source
        self.chars = Array(source)
    }

    // MARK: Character IO

    private var eof: Bool { index >= chars.count }

    private func peek(offset: Int = 0) -> Character? {
        let i = index + offset
        return i < chars.count ? chars[i] : nil
    }

    private func getc(removeQuotedNewline: Bool = true) -> Character? {
        while index < chars.count {
            let c = chars[index]
            index += 1
            if c == "\\",
               removeQuotedNewline,
               index < chars.count,
               chars[index] == "\n"
            {
                index += 1
                continue
            }
            return c
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
        // Track the last three tokens for reserved-word / assignment decisions.
        twoTokensAgo = tokenBeforeThat
        tokenBeforeThat = lastReadToken
        lastReadToken = token
        return token
    }

    /// Non-consuming peek at the next token. Subsequent peeks/nexts see the same token.
    private var lookahead: Token?

    public func peekToken() throws -> Token {
        if let la = lookahead { return la }
        let t = try nextToken()
        lookahead = t
        return t
    }

    public func consume() throws -> Token {
        if let la = lookahead {
            lookahead = nil
            return la
        }
        return try nextToken()
    }

    // MARK: - Core reader

    private func readTokenInternal() throws -> Token {
        // skip blanks
        while let c = peek(), SyntaxClass.isBlank(c) {
            _ = getc()
        }

        // comments: swallow until newline (but don't consume it)
        if peek() == "#" {
            while let c = peek(), c != "\n" {
                _ = getc()
            }
        }

        guard let c = peek() else {
            return Token(type: .eof, value: "", range: chars.count..<chars.count)
        }

        let start = index

        if c == "\n" {
            _ = getc()
            // gather any pending heredocs immediately after this newline
            try gatherPendingHeredocs()
            return Token(type: .newline, value: "\n", range: start..<start + 1)
        }

        if SyntaxClass.isMeta(c) {
            return try readMetaToken(startingAt: start)
        }

        // `-` after `<&` or `>&` stands alone as a DASH token
        if c == "-" {
            if let lrt = lastReadToken,
               lrt.type == .lessAnd || lrt.type == .greaterAnd
            {
                _ = getc()
                return Token(type: .dash, value: "-", range: start..<start + 1)
            }
        }

        return try readTokenWord()
    }

    // MARK: Meta-token reader

    private func readMetaToken(startingAt start: Int) throws -> Token {
        let c = getc()!
        let p = peek()

        // Double-character
        if let p, p == c {
            if c == "<" {
                _ = getc()
                let q = peek()
                if q == "-" {
                    _ = getc()
                    return Token(type: .lessLessMinus, value: "<<-", range: start..<index)
                } else if q == "<" {
                    _ = getc()
                    return Token(type: .lessLessLess, value: "<<<", range: start..<index)
                } else {
                    return Token(type: .lessLess, value: "<<", range: start..<index)
                }
            }
            if c == ">" {
                _ = getc()
                return Token(type: .greaterGreater, value: ">>", range: start..<index)
            }
            if c == ";" {
                _ = getc()
                if peek() == "&" {
                    _ = getc()
                    return Token(type: .semiSemiAnd, value: ";;&", range: start..<index)
                }
                return Token(type: .semiSemi, value: ";;", range: start..<index)
            }
            if c == "&" {
                _ = getc()
                return Token(type: .andAnd, value: "&&", range: start..<index)
            }
            if c == "|" {
                _ = getc()
                return Token(type: .orOr, value: "||", range: start..<index)
            }
            // "(("/"))" etc. — not currently distinguished as compound operators.
            // Fall through to single-char handling.
        }

        // Two-character combinations
        if let p {
            switch (c, p) {
            case ("<", "&"):
                _ = getc()
                return Token(type: .lessAnd, value: "<&", range: start..<index)
            case (">", "&"):
                _ = getc()
                return Token(type: .greaterAnd, value: ">&", range: start..<index)
            case ("<", ">"):
                _ = getc()
                return Token(type: .lessGreater, value: "<>", range: start..<index)
            case (">", "|"):
                _ = getc()
                return Token(type: .greaterBar, value: ">|", range: start..<index)
            case ("&", ">"):
                _ = getc()
                if peek() == ">" {
                    _ = getc()
                    return Token(type: .andGreaterGreater, value: "&>>",
                                 range: start..<index)
                }
                return Token(type: .andGreater, value: "&>", range: start..<index)
            case ("|", "&"):
                _ = getc()
                return Token(type: .barAnd, value: "|&", range: start..<index)
            case (";", "&"):
                _ = getc()
                return Token(type: .semiAnd, value: ";&", range: start..<index)
            case ("<", "("):
                return try readProcessSubstWord(start: start, op: "<")
            case (">", "("):
                return try readProcessSubstWord(start: start, op: ">")
            default:
                break
            }
        }

        // Single-character meta
        switch c {
        case "(": return Token(type: .leftParen,  value: "(", range: start..<index)
        case ")": return Token(type: .rightParen, value: ")", range: start..<index)
        case "|": return Token(type: .bar,        value: "|", range: start..<index)
        case "&": return Token(type: .ampersand,  value: "&", range: start..<index)
        case ";": return Token(type: .semicolon,  value: ";", range: start..<index)
        case "<": return Token(type: .less,       value: "<", range: start..<index)
        case ">": return Token(type: .greater,    value: ">", range: start..<index)
        default:
            throw BashSyntaxError.parsing(
                message: "unexpected meta character '\(c)'",
                source: source, position: start)
        }
    }

    /// Read `<(...)` or `>(...)` as a single WORD token whose value contains the
    /// delimiters and the balanced body.
    private func readProcessSubstWord(start: Int, op: String) throws -> Token {
        // We already consumed the `<` or `>`; now consume `(` and balance.
        _ = getc() // consume '('
        let body = try parseMatchedPair(doubleQuote: nil, open: "(", close: ")")
        let value = "\(op)(\(body)"
        var flags: TokenFlags = [.hasDollar]
        flags.insert(.quoted) // treat as quoted for word-expansion purposes
        return Token(type: .word, value: value, range: start..<index, flags: flags)
    }

    // MARK: Word reader

    private func readTokenWord() throws -> Token {
        let start = index
        var word = ""
        var allDigits = true
        var hasDollar = false
        var quoted = false
        var doubleQuoted = false
        let compAssign = false
        var passNext = false

        loop: while let c = peek() {
            if passNext {
                passNext = false
                word.append(c); _ = getc()
                if !c.isASCIIDigit { allDigits = false }
                if !hasDollar && c == "$" { hasDollar = true }
                continue
            }

            let cd = delimiters.last // current delimiter (from nested parse)

            if c == "\\" {
                // Look at next char; if it's a newline, it's consumed implicitly
                // by getc() already (line continuation). Otherwise include both.
                _ = getc() // consume the backslash
                if let next = peek() {
                    if next == "\n" {
                        _ = getc() // skip escaped newline
                        continue
                    }
                    // Inside single quotes we wouldn't be here at all; for
                    // default context or double-quote-dquote chars, include.
                    word.append(c)
                    passNext = true
                    quoted = true
                    continue
                } else {
                    word.append(c)
                    break
                }
            }

            if SyntaxClass.isQuoteChar(c) {
                // Read matched pair including the delimiters.
                _ = getc() // consume opening quote
                delimiters.append(c)
                let body = try parseMatchedPair(
                    doubleQuote: c, open: c, close: c,
                    parsingCommand: c == "`"
                )
                delimiters.removeLast()
                word.append(c)
                word.append(contentsOf: body)
                allDigits = false
                quoted = true
                if c == "\"" { doubleQuoted = true }
                if !hasDollar && c == "\"" && body.contains("$") {
                    hasDollar = true
                }
                continue
            }

            if SyntaxClass.isExp(c) {
                let consumed = try handleShellExp(word: &word,
                                                  hasDollar: &hasDollar,
                                                  allDigits: &allDigits,
                                                  quoted: &quoted)
                if consumed { continue }
                // Fall through: `<` / `>` without `(` should be treated as a
                // break when not inside a delimiter context.
            }

            if SyntaxClass.isBreak(c) {
                // Leave break char in input for the outer loop
                break loop
            }

            // Default: consume
            _ = getc()
            word.append(c)
            if !c.isASCIIDigit { allDigits = false }
            if !hasDollar && c == "$" { hasDollar = true }
            _ = cd // silence unused-var warning when delimiters stack helpers
                   // are not used in this compact variant
        }

        let end = index
        let range = start..<end

        // Empty words are bugs: the outer loop must only call readTokenWord when
        // there is a non-blank, non-meta character waiting.
        if word.isEmpty {
            throw BashSyntaxError.parsing(message: "empty token",
                                       source: source, position: start)
        }

        // NUMBER token: all-digit words in redirect positions
        if allDigits,
           let p = peek(), (p == "<" || p == ">"),
           let n = Int(word)
        {
            return Token(type: .number, value: "\(n)", range: range)
        }

        // Special-case: `in` after `WORD` + (FOR|CASE|SELECT)
        //               `do` after `WORD` + (FOR|SELECT)
        if !hasDollar, !quoted,
           let prev = lastReadToken, prev.type == .word,
           let tbt = tokenBeforeThat
        {
            if word == "in",
               tbt.type == .forKw || tbt.type == .caseKw || tbt.type == .selectKw
            {
                if tbt.type == .caseKw { inCasePat = true }
                return Token(type: .inKw, value: word, range: range)
            }
            if word == "do",
               tbt.type == .forKw || tbt.type == .selectKw
            {
                return Token(type: .doKw, value: word, range: range)
            }
        }

        // Reserved word?
        if !hasDollar, !quoted, reservedWordAcceptable() {
            if let rw = TokenType.reservedWordTable[word] {
                if inCasePat && rw != .esacKw {
                    // don't reserve
                } else {
                    switch rw {
                    case .esacKw: inCasePat = false
                    case .caseKw: break
                    case .leftCurly: openBraces += 1
                    case .rightCurly where openBraces > 0: openBraces -= 1
                    case .inKw:
                        if let tbt = tokenBeforeThat, tbt.type == .caseKw {
                            inCasePat = true
                        }
                    default: break
                    }
                    return Token(type: rw, value: word, range: range)
                }
            }
        }

        // Assignment detection
        var flags: TokenFlags = []
        if hasDollar { flags.insert(.hasDollar) }
        if quoted { flags.insert(.quoted) }
        if doubleQuoted { flags.insert(.doubleQuoted) }
        if compAssign { flags.insert(.compAssign) }

        if let eqIdx = assignmentPrefixLength(in: word) {
            flags.insert(.assignment)
            if assignmentAcceptable() {
                flags.insert(.noSplit)
                _ = eqIdx
                return Token(type: .assignmentWord, value: word,
                             range: range, flags: flags)
            }
        }

        // Brace variable redirection: `{name}<`, `{name}>`
        if word.first == "{", word.last == "}",
           let p = peek(), (p == "<" || p == ">"),
           isLegalIdentifier(String(word.dropFirst().dropLast()))
        {
            let bare = String(word.dropFirst().dropLast())
            return Token(type: .redirectWord, value: bare,
                         range: range, flags: flags)
        }

        return Token(type: .word, value: word, range: range, flags: flags)
    }

    // MARK: Expansion & substitution

    /// Handle `$`, `<`, `>` expansion-initiators inside a word. Returns `true`
    /// if characters were consumed as an expansion; `false` if the caller
    /// should handle `c` as a literal character.
    private func handleShellExp(word: inout String,
                                hasDollar: inout Bool,
                                allDigits: inout Bool,
                                quoted: inout Bool) throws -> Bool {
        guard let c = peek() else { return false }

        if c == "<" || c == ">" {
            // Process substitution only if followed by `(`.
            guard peek(offset: 1) == "(" else { return false }
            let start = index
            _ = getc() // <
            _ = getc() // (
            let body = try parseMatchedPair(doubleQuote: nil, open: "(", close: ")")
            word.append(String(chars[start..<index]))
            _ = body
            hasDollar = true
            allDigits = false
            return true
        }

        // c == '$'
        guard c == "$" else { return false }

        let peekNext = peek(offset: 1)
        switch peekNext {
        case "(":
            _ = getc() // $
            _ = getc() // (
            word.append("$(")
            if peek() == "(" {
                // $((...)): arithmetic expansion, take it matched as (( .. ))
                _ = getc()
                word.append("(")
                let body = try parseMatchedPair(doubleQuote: nil, open: "(", close: ")")
                word.append(body)
                // consume the extra closing paren if present
                if peek() == ")" {
                    _ = getc()
                    word.append(")")
                }
            } else {
                let body = try parseCommandSubstitution()
                word.append(body)
            }
            hasDollar = true
            allDigits = false
            return true

        case "{":
            _ = getc() // $
            _ = getc() // {
            let body = try parseMatchedPair(doubleQuote: nil, open: "{", close: "}",
                                            firstClose: true, dolbrace: true)
            word.append("${"); word.append(body)
            hasDollar = true
            allDigits = false
            return true

        case "[":
            // Arithmetic $[..] (deprecated)
            _ = getc(); _ = getc()
            let body = try parseMatchedPair(doubleQuote: nil, open: "[", close: "]")
            word.append("$["); word.append(body)
            hasDollar = true
            allDigits = false
            return true

        case "'":
            _ = getc(); _ = getc()
            let body = try parseMatchedPair(doubleQuote: "'", open: "'", close: "'",
                                            allowEsc: true)
            word.append("$'"); word.append(body)
            quoted = true
            allDigits = false
            return true

        case "\"":
            _ = getc(); _ = getc()
            let body = try parseMatchedPair(doubleQuote: "\"", open: "\"", close: "\"")
            word.append("$\""); word.append(body)
            quoted = true
            allDigits = false
            return true

        case "$":
            _ = getc(); _ = getc()
            word.append("$$")
            hasDollar = true
            allDigits = false
            return true

        default:
            // Plain `$var`, `$1`, `$?`, etc. — just consume the `$` and let the
            // rest get picked up by the word loop.
            _ = getc()
            word.append("$")
            hasDollar = true
            allDigits = false
            return true
        }
    }

    // MARK: parseMatchedPair / parseComsub

    /// Consume characters up to a matching `close`, balancing nested quotes
    /// and substitutions, and return the content between (but not including)
    /// the delimiters. The closing delimiter is consumed.
    private func parseMatchedPair(doubleQuote: Character?,
                                  open: Character,
                                  close: Character,
                                  parsingCommand: Bool = false,
                                  allowEsc: Bool = false,
                                  dquote: Bool = false,
                                  firstClose: Bool = false,
                                  dolbrace: Bool = false) throws -> String {
        var count = 1
        var out = ""
        var passNext = false
        var sawDollar = false

        while count > 0 {
            guard let c = getc(removeQuotedNewline: doubleQuote != "'" && !passNext) else {
                throw BashSyntaxError.parsing(
                    message: "unexpected EOF while looking for matching '\(close)'",
                    source: source, position: index)
            }

            if passNext {
                passNext = false
                out.append(c)
                sawDollar = false
                continue
            }

            if c == close {
                count -= 1
                out.append(c)
                if count == 0 { break }
                sawDollar = (c == "$")
                continue
            }

            if !firstClose && c == open {
                count += 1
                out.append(c)
                sawDollar = (c == "$")
                continue
            }

            out.append(c)

            if open == "'" {
                if allowEsc && c == "\\" { passNext = true }
                continue
            }

            if c == "\\" { passNext = true; sawDollar = false; continue }

            if open != close {
                if SyntaxClass.isQuoteChar(c) {
                    delimiters.append(c)
                    let nested = try parseMatchedPair(doubleQuote: c, open: c, close: c,
                                                      parsingCommand: parsingCommand,
                                                      allowEsc: allowEsc || (sawDollar && c == "'"),
                                                      dquote: dquote,
                                                      firstClose: firstClose,
                                                      dolbrace: dolbrace)
                    delimiters.removeLast()
                    out.append(nested) // includes closing quote
                    sawDollar = false
                    continue
                }
            } else if open == "\"" && c == "`" {
                // Backticks inside double quotes are recursively parsed.
                let nested = try parseMatchedPair(doubleQuote: nil, open: "`", close: "`",
                                                  parsingCommand: parsingCommand,
                                                  allowEsc: allowEsc,
                                                  dquote: dquote,
                                                  firstClose: firstClose,
                                                  dolbrace: dolbrace)
                out.append(nested) // includes closing backtick
                sawDollar = false
                continue
            }

            // $( / ${ / $[ inside the matched pair (open != `).
            if open != "`", sawDollar, (c == "(" || c == "{" || c == "[") {
                let innerOpen = c
                let innerClose: Character
                switch c {
                case "(": innerClose = ")"
                case "{": innerClose = "}"
                case "[": innerClose = "]"
                default: innerClose = c
                }
                if c == "(" {
                    let nested = try parseCommandSubstitution()
                    out.append(nested) // includes closing ')'
                } else {
                    let nested = try parseMatchedPair(doubleQuote: nil,
                                                      open: innerOpen,
                                                      close: innerClose,
                                                      parsingCommand: false,
                                                      allowEsc: allowEsc,
                                                      dquote: dquote,
                                                      firstClose: c == "{",
                                                      dolbrace: c == "{")
                    out.append(nested) // includes closing delimiter
                }
                sawDollar = false
                continue
            }

            sawDollar = (c == "$")
        }

        return out
    }

    /// Parse the body of a `$(...)` command substitution up to (and consuming)
    /// the matching `)`. Returns the raw body text followed by a `)`.
    private func parseCommandSubstitution() throws -> String {
        // Peek for `((` — arithmetic — then defer to simpler matched-pair.
        if peek() == "(" {
            return try parseMatchedPair(doubleQuote: nil, open: "(", close: ")")
        }

        // Walk the command body as raw text while respecting quotes and
        // nested substitutions. The parser will recursively re-tokenize this
        // body later, so the lexical phase only needs to locate the matching
        // close paren.
        var count = 1
        var out = ""
        var passNext = false
        var sawDollar = false

        while count > 0 {
            guard let c = getc(removeQuotedNewline: !passNext) else {
                throw BashSyntaxError.parsing(
                    message: "unexpected EOF while looking for matching ')'",
                    source: source, position: index)
            }
            if passNext {
                passNext = false
                out.append(c)
                continue
            }
            if c == "\\" {
                out.append(c); passNext = true; continue
            }
            if c == ")" {
                count -= 1
                if count == 0 {
                    out.append(c)
                    break
                }
                out.append(c)
                sawDollar = false
                continue
            }
            if c == "(" {
                count += 1
                out.append(c)
                sawDollar = false
                continue
            }
            if SyntaxClass.isQuoteChar(c) {
                out.append(c)
                delimiters.append(c)
                let nested = try parseMatchedPair(doubleQuote: c, open: c, close: c,
                                                  parsingCommand: c == "`")
                delimiters.removeLast()
                out.append(nested) // includes closing quote
                sawDollar = false
                continue
            }
            if sawDollar, c == "{" {
                let nested = try parseMatchedPair(doubleQuote: nil, open: "{", close: "}",
                                                  firstClose: true, dolbrace: true)
                out.append(nested) // includes closing '}'
                sawDollar = false
                continue
            }
            out.append(c)
            sawDollar = (c == "$")
        }

        return out
    }

    // MARK: Reserved-word / assignment heuristics

    private func reservedWordAcceptable() -> Bool {
        guard let lrt = lastReadToken else { return true }
        if TokenType.commandStartTypes.contains(lrt.type) { return true }
        // `function foo` — allow `{` after the name.
        if lrt.type == .word,
           let tbt = tokenBeforeThat, tbt.type == .functionKw
        {
            return true
        }
        return false
    }

    private func assignmentAcceptable() -> Bool {
        // Accept only at command position (the same contexts that allow reserved words).
        return reservedWordAcceptable()
    }

    private func assignmentPrefixLength(in s: String) -> Int? {
        let chars = Array(s)
        guard let first = chars.first, first.isLetter || first == "_" else {
            return nil
        }
        for (i, c) in chars.enumerated() {
            if c == "=" { return i }
            if c == "+", i + 1 < chars.count, chars[i + 1] == "=" { return i + 1 }
            if !(c.isLetter || c.isNumber || c == "_") { return nil }
        }
        return nil
    }

    private func isLegalIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: Heredoc gathering

    /// Called when we've just consumed a NEWLINE — read heredoc bodies for
    /// any redirects queued since the previous newline.
    private func gatherPendingHeredocs() throws {
        guard !pendingHeredocs.isEmpty else { return }
        for (i, h) in pendingHeredocs.enumerated() {
            var hh = h
            let bodyStart = index
            var body = ""

            while true {
                let lineStart = index
                // Read to end-of-line (or EOF)
                var line = ""
                while let c = getc(removeQuotedNewline: false), c != "\n" {
                    line.append(c)
                }

                // Tab-stripping for `<<-`
                let stripped: String
                if hh.stripTabs {
                    stripped = String(line.drop(while: { $0 == "\t" }))
                } else {
                    stripped = line
                }

                if stripped == hh.delimiter {
                    let bodyEnd = lineStart
                    hh.bodyRange = bodyStart..<bodyEnd
                    hh.body = body
                    heredocBodies[hh.start] = (body: body,
                                               range: bodyStart..<bodyEnd)
                    break
                }
                // Include the original (un-stripped) line + newline in body
                body.append(line)
                body.append("\n")
                if eof {
                    hh.bodyRange = bodyStart..<index
                    hh.body = body
                    heredocBodies[hh.start] = (body: body,
                                               range: bodyStart..<index)
                    break
                }
            }
            pendingHeredocs[i] = hh
        }
        pendingHeredocs.removeAll()
    }

    /// Register a pending heredoc. The parser calls this after building a
    /// `<<` or `<<-` redirect so the body can be collected on the next newline.
    func registerHeredoc(delimiter: String, stripTabs: Bool, start: Int) {
        pendingHeredocs.append(
            PendingHeredoc(delimiter: delimiter, stripTabs: stripTabs,
                           start: start, bodyRange: nil, body: nil))
    }
}
