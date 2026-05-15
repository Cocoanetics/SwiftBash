import Foundation

// Lexical helpers for the bash tokenizer: shell expansions, matched
// pair scanners, arithmetic bodies, heredoc gathering, and assignment-
// prefix recognition. Split out from `Tokenizer.swift` to keep the
// driver class within the type-body / file-length limits.

extension Tokenizer {

    // Handle `$`, `<`, `>` expansion-initiators inside a word. Returns `true`
    // if characters were consumed as an expansion; `false` if the caller
    // should handle the character as a literal. Handles every bash expansion
    // prefix (`$`, `<(`, `>(`) plus the `${`, `$(`, `$'`, `$"`, `$$`, `$[`
    // variants; splitting would hide the table-driven control flow.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func handleShellExp(word: inout String,
                        hasDollar: inout Bool,
                        allDigits: inout Bool,
                        quoted: inout Bool) throws -> Bool {
        guard let char = peek() else { return false }

        if char == "<" || char == ">" {
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
        guard char == "$" else { return false }

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

    // Bash assignment prefix recognition walks an identifier, an optional
    // bracket subscript, and either `=` or `+=`; one branch per literal.
    // swiftlint:disable:next cyclomatic_complexity
    func assignmentPrefixLength(in text: String) -> Int? {
        let textChars = Array(text)
        guard let first = textChars.first, first.isLetter || first == "_" else {
            return nil
        }
        var pos = 0
        // Identifier head.
        while pos < textChars.count {
            let char = textChars[pos]
            if char.isLetter || char.isNumber || char == "_" { pos += 1; continue }
            break
        }
        // Optional `[subscript]` for array-element assignment
        // (`arr[2]=x`). The subscript text is preserved in the
        // assignment-word value; the interpreter splits it out.
        if pos < textChars.count, textChars[pos] == "[" {
            var depth = 1
            pos += 1
            while pos < textChars.count, depth > 0 {
                if textChars[pos] == "[" {
                    depth += 1
                } else if textChars[pos] == "]" {
                    depth -= 1
                }
                pos += 1
            }
            if depth != 0 { return nil }
        }
        // `=` or `+=`
        guard pos < textChars.count else { return nil }
        if textChars[pos] == "=" { return pos }
        if textChars[pos] == "+",
           pos + 1 < textChars.count, textChars[pos + 1] == "=" {
            return pos + 1
        }
        return nil
    }

    func isLegalIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // Called when we've just consumed a NEWLINE — read heredoc bodies for
    // any redirects queued since the previous newline.
    func gatherPendingHeredocs() throws {
        guard !pendingHeredocs.isEmpty else { return }
        for (slot, pending) in pendingHeredocs.enumerated() {
            var here = pending
            let bodyStart = index
            var body = ""

            while true {
                let lineStart = index
                // Read to end-of-line (or EOF)
                var line = ""
                while let char = getc(removeQuotedNewline: false), char != "\n" {
                    line.append(char)
                }

                // Tab-stripping for `<<-`
                let stripped: String
                if here.stripTabs {
                    stripped = String(line.drop(while: { $0 == "\t" }))
                } else {
                    stripped = line
                }

                if stripped == here.delimiter {
                    let bodyEnd = lineStart
                    here.bodyRange = bodyStart..<bodyEnd
                    here.body = body
                    heredocBodies[here.start] = (body: body,
                                                 range: bodyStart..<bodyEnd)
                    break
                }
                // For `<<-` the leading tabs are stripped from the body
                // line as well as the delimiter check (POSIX). Plain
                // `<<` keeps the line verbatim.
                body.append(here.stripTabs ? stripped : line)
                body.append("\n")
                if eof {
                    here.bodyRange = bodyStart..<index
                    here.body = body
                    heredocBodies[here.start] = (body: body,
                                                 range: bodyStart..<index)
                    break
                }
            }
            pendingHeredocs[slot] = here
        }
        pendingHeredocs.removeAll()
    }
}
