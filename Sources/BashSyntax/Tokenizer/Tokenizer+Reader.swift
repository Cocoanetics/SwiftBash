import Foundation

// Meta-token / word readers plus the reserved-word and assignment
// heuristics they depend on. Split out from `Tokenizer.swift` to keep
// the driver class within the type-body / file-length limits.

extension Tokenizer {

    // MARK: Meta-token reader

    // The bash meta-operator table is large by spec; splitting per-case
    // would not improve readability of the dispatch.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func readMetaToken(startingAt start: Int) throws -> Token {
        let char = getc()!
        let nextChar = peek()

        // `((` at a command-acceptable position starts an arithmetic command.
        // (A subshell-inside-subshell needs whitespace between the parens:
        // `( (…) )` — so `((` with no blank unambiguously opens arithmetic.)
        if char == "(", nextChar == "(", reservedWordAcceptable() {
            _ = getc() // consume the second `(`
            let body = try readArithmeticBody(startPos: start)
            return Token(type: .arithCommand, value: body,
                         range: start..<index)
        }

        // Double-character
        if let nextChar, nextChar == char {
            if char == "<" {
                _ = getc()
                let third = peek()
                if third == "-" {
                    _ = getc()
                    return Token(type: .lessLessMinus, value: "<<-", range: start..<index)
                } else if third == "<" {
                    _ = getc()
                    return Token(type: .lessLessLess, value: "<<<", range: start..<index)
                } else {
                    return Token(type: .lessLess, value: "<<", range: start..<index)
                }
            }
            if char == ">" {
                _ = getc()
                return Token(type: .greaterGreater, value: ">>", range: start..<index)
            }
            if char == ";" {
                _ = getc()
                if peek() == "&" {
                    _ = getc()
                    return Token(type: .semiSemiAnd, value: ";;&", range: start..<index)
                }
                return Token(type: .semiSemi, value: ";;", range: start..<index)
            }
            if char == "&" {
                _ = getc()
                return Token(type: .andAnd, value: "&&", range: start..<index)
            }
            if char == "|" {
                _ = getc()
                return Token(type: .orOr, value: "||", range: start..<index)
            }
            // "(("/"))" etc. — not currently distinguished as compound operators.
            // Fall through to single-char handling.
        }

        // Two-character combinations
        if let nextChar {
            switch (char, nextChar) {
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
                return try readProcessSubstWord(start: start, prefix: "<")
            case (">", "("):
                return try readProcessSubstWord(start: start, prefix: ">")
            default:
                break
            }
        }

        // Single-character meta
        switch char {
        case "(": return Token(type: .leftParen, value: "(", range: start..<index)
        case ")": return Token(type: .rightParen, value: ")", range: start..<index)
        case "|": return Token(type: .bar, value: "|", range: start..<index)
        case "&": return Token(type: .ampersand, value: "&", range: start..<index)
        case ";": return Token(type: .semicolon, value: ";", range: start..<index)
        case "<": return Token(type: .less, value: "<", range: start..<index)
        case ">": return Token(type: .greater, value: ">", range: start..<index)
        default:
            throw BashSyntaxError.parsing(
                message: "unexpected meta character '\(char)'",
                source: source, position: start)
        }
    }

    // Read `<(...)` or `>(...)` as a single WORD token whose value contains the
    // delimiters and the balanced body.
    func readProcessSubstWord(start: Int, prefix: String) throws -> Token {
        // We already consumed the `<` or `>`; now consume `(` and balance.
        _ = getc() // consume '('
        let body = try parseMatchedPair(doubleQuote: nil, open: "(", close: ")")
        let value = "\(prefix)(\(body)"
        var flags: TokenFlags = [.hasDollar]
        flags.insert(.quoted) // treat as quoted for word-expansion purposes
        return Token(type: .word, value: value, range: start..<index, flags: flags)
    }

    // MARK: Word reader

    // Word tokenization handles dozens of bash-spec branches by design.
    // Splitting would scatter the loop state into helpers.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func readTokenWord() throws -> Token {
        let start = index
        var word = ""
        var allDigits = true
        var hasDollar = false
        var quoted = false
        var doubleQuoted = false
        let compAssign = false
        var passNext = false

        loop: while let char = peek() {
            if passNext {
                passNext = false
                word.append(char); _ = getc()
                if !char.isASCIIDigit { allDigits = false }
                if !hasDollar && char == "$" { hasDollar = true }
                continue
            }

            let currentDelim = delimiters.last // current delimiter (from nested parse)

            // Line continuation: `\<NL>` is removed silently mid-word
            // (POSIX), so `a\<NL>b` tokenises to a single word `ab`.
            if char == "\\", peek(offset: 1) == "\n" {
                index += 2
                continue
            }

            if char == "\\" {
                // Pass `removeQuotedNewline: false` so we consume only the
                // backslash itself; otherwise getc would silently swallow
                // the trailing `\n` AND the next character, dropping bytes.
                _ = getc(removeQuotedNewline: false)
                if let next = peek() {
                    if next == "\n" {
                        _ = getc(removeQuotedNewline: false)
                        continue
                    }
                    // Inside single quotes we wouldn't be here at all; for
                    // default context or double-quote-dquote chars, include.
                    word.append(char)
                    passNext = true
                    quoted = true
                    continue
                } else {
                    word.append(char)
                    break
                }
            }

            if SyntaxClass.isQuoteChar(char) {
                // Read matched pair including the delimiters.
                _ = getc() // consume opening quote
                delimiters.append(char)
                let body = try parseMatchedPair(
                    doubleQuote: char, open: char, close: char,
                    parsingCommand: char == "`"
                )
                delimiters.removeLast()
                word.append(char)
                word.append(contentsOf: body)
                allDigits = false
                quoted = true
                if char == "\"" { doubleQuoted = true }
                if !hasDollar && char == "\"" && body.contains("$") {
                    hasDollar = true
                }
                continue
            }

            if SyntaxClass.isExp(char) {
                let consumed = try handleShellExp(word: &word,
                                                  hasDollar: &hasDollar,
                                                  allDigits: &allDigits,
                                                  quoted: &quoted)
                if consumed { continue }
                // Fall through: `<` / `>` without `(` should be treated as a
                // break when not inside a delimiter context.
            }

            // Extended-glob construct: `?(p)` `*(p)` `+(p)` `@(p)` `!(p)`
            // appearing in pattern context (case patterns, [[ ]]). The
            // construct lives inside the word so the parser sees a
            // single pattern token.
            if char == "(",
               let prev = word.last,
               "?*+@!".contains(prev),
               inCasePat || inExtglobPattern {
                _ = getc()              // consume `(`
                word.append(char)
                let body = try parseMatchedPair(
                    doubleQuote: nil, open: "(", close: ")")
                word.append(contentsOf: body)
                quoted = true           // suppress reserved-word demotion
                allDigits = false
                continue
            }

            if SyntaxClass.isBreak(char) {
                // Leave break char in input for the outer loop
                break loop
            }

            // Default: consume
            _ = getc()
            word.append(char)
            if !char.isASCIIDigit { allDigits = false }
            if !hasDollar && char == "$" { hasDollar = true }
            _ = currentDelim // silence unused-var warning when delimiters
                             // stack helpers are not used in this variant
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
           let nextChar = peek(), nextChar == "<" || nextChar == ">",
           let number = Int(word) {
            return Token(type: .number, value: "\(number)", range: range)
        }

        // Special-case: `in` after `WORD` + (FOR|CASE|SELECT)
        //               `do` after `WORD` + (FOR|SELECT)
        if !hasDollar, !quoted,
           let prev = lastReadToken, prev.type == .word,
           let prior = tokenBeforeThat {
            if word == "in",
               prior.type == .forKw || prior.type == .caseKw || prior.type == .selectKw {
                if prior.type == .caseKw { inCasePat = true }
                return Token(type: .inKw, value: word, range: range)
            }
            if word == "do",
               prior.type == .forKw || prior.type == .selectKw {
                return Token(type: .doKw, value: word, range: range)
            }
        }

        // Reserved word?
        if !hasDollar, !quoted, reservedWordAcceptable() {
            if let reservedWord = TokenType.reservedWordTable[word] {
                if inCasePat && reservedWord != .esacKw {
                    // don't reserve
                } else {
                    switch reservedWord {
                    case .esacKw: inCasePat = false
                    case .caseKw: break
                    case .leftCurly: openBraces += 1
                    case .rightCurly where openBraces > 0: openBraces -= 1
                    case .inKw:
                        if let prior = tokenBeforeThat, prior.type == .caseKw {
                            inCasePat = true
                        }
                    default: break
                    }
                    return Token(type: reservedWord, value: word, range: range)
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
           let nextChar = peek(), nextChar == "<" || nextChar == ">",
           isLegalIdentifier(String(word.dropFirst().dropLast())) {
            let bare = String(word.dropFirst().dropLast())
            return Token(type: .redirectWord, value: bare,
                         range: range, flags: flags)
        }

        return Token(type: .word, value: word, range: range, flags: flags)
    }

    // MARK: Reserved-word / assignment heuristics

    func reservedWordAcceptable() -> Bool {
        guard let lrt = lastReadToken else { return true }
        if TokenType.commandStartTypes.contains(lrt.type) { return true }
        // `function foo` — allow `{` after the name.
        if lrt.type == .word,
           let tbt = tokenBeforeThat, tbt.type == .functionKw {
            return true
        }
        return false
    }

    func assignmentAcceptable() -> Bool {
        // Normal case: only at command position (where reserved words
        // would also be acceptable).
        if reservedWordAcceptable() { return true }
        // Bash exception: arguments to the assignment-built-ins
        // (`declare`, `typeset`, `local`, `readonly`, `export`) are
        // also tokenized as assignment-style. Keeps `declare -a a=(…)`
        // and `local x=1 y=2` parsing the way real bash does.
        return inDeclarationContext
    }
}
