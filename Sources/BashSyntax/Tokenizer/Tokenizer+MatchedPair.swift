import Foundation

// Recursive matched-pair, command-substitution, and arithmetic-body
// parsers used by the bash tokenizer. Split out from
// `Tokenizer+Parsing.swift` to keep both files under the file-length
// limit.

extension Tokenizer {

    // Consume characters up to a matching `close`, balancing nested quotes
    // and substitutions, and return the content between (but not including)
    // the delimiters. The closing delimiter is consumed. Matched-pair
    // parsing recurses across every bash quote/expansion variant; the
    // branches map 1:1 to spec cases so splitting would obscure the state
    // machine.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func parseMatchedPair(doubleQuote: Character?,
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
            guard let char = getc(removeQuotedNewline: doubleQuote != "'" && !passNext) else {
                throw BashSyntaxError.parsing(
                    message: "unexpected EOF while looking for matching '\(close)'",
                    source: source, position: index)
            }

            if passNext {
                passNext = false
                out.append(char)
                sawDollar = false
                continue
            }

            if char == close {
                count -= 1
                out.append(char)
                if count == 0 { break }
                sawDollar = (char == "$")
                continue
            }

            if !firstClose && char == open {
                count += 1
                out.append(char)
                sawDollar = (char == "$")
                continue
            }

            out.append(char)

            if open == "'" {
                if allowEsc && char == "\\" { passNext = true }
                continue
            }

            if char == "\\" { passNext = true; sawDollar = false; continue }

            if open != close {
                if SyntaxClass.isQuoteChar(char) {
                    delimiters.append(char)
                    let nested = try parseMatchedPair(doubleQuote: char, open: char, close: char,
                                                      parsingCommand: parsingCommand,
                                                      allowEsc: allowEsc || (sawDollar && char == "'"),
                                                      dquote: dquote,
                                                      firstClose: firstClose,
                                                      dolbrace: dolbrace)
                    delimiters.removeLast()
                    out.append(nested) // includes closing quote
                    sawDollar = false
                    continue
                }
            } else if open == "\"" && char == "`" {
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
            if open != "`", sawDollar, char == "(" || char == "{" || char == "[" {
                let innerOpen = char
                let innerClose: Character
                switch char {
                case "(": innerClose = ")"
                case "{": innerClose = "}"
                case "[": innerClose = "]"
                default: innerClose = char
                }
                if char == "(" {
                    let nested = try parseCommandSubstitution()
                    out.append(nested) // includes closing ')'
                } else {
                    let nested = try parseMatchedPair(doubleQuote: nil,
                                                      open: innerOpen,
                                                      close: innerClose,
                                                      parsingCommand: false,
                                                      allowEsc: allowEsc,
                                                      dquote: dquote,
                                                      firstClose: char == "{",
                                                      dolbrace: char == "{")
                    out.append(nested) // includes closing delimiter
                }
                sawDollar = false
                continue
            }

            sawDollar = (char == "$")
        }

        return out
    }

    // Parse the body of a `$(...)` command substitution up to (and consuming)
    // the matching `)`. Returns the raw body text followed by a `)`.
    // Command-substitution body walker covers shell quoting and nested
    // expansions; one switch per character.
    // swiftlint:disable:next function_body_length
    func parseCommandSubstitution() throws -> String {
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
            guard let char = getc(removeQuotedNewline: !passNext) else {
                throw BashSyntaxError.parsing(
                    message: "unexpected EOF while looking for matching ')'",
                    source: source, position: index)
            }
            if passNext {
                passNext = false
                out.append(char)
                continue
            }
            if char == "\\" {
                out.append(char); passNext = true; continue
            }
            if char == ")" {
                count -= 1
                if count == 0 {
                    out.append(char)
                    break
                }
                out.append(char)
                sawDollar = false
                continue
            }
            if char == "(" {
                count += 1
                out.append(char)
                sawDollar = false
                continue
            }
            if SyntaxClass.isQuoteChar(char) {
                out.append(char)
                delimiters.append(char)
                let nested = try parseMatchedPair(doubleQuote: char, open: char, close: char,
                                                  parsingCommand: char == "`")
                delimiters.removeLast()
                out.append(nested) // includes closing quote
                sawDollar = false
                continue
            }
            if sawDollar, char == "{" {
                let nested = try parseMatchedPair(doubleQuote: nil, open: "{", close: "}",
                                                  firstClose: true, dolbrace: true)
                out.append(char)     // include the opening '{'
                out.append(nested)   // body + closing '}'
                sawDollar = false
                continue
            }
            out.append(char)
            sawDollar = (char == "$")
        }

        return out
    }

    // Read the body inside an `((…))` or `$((…))` up to (and consuming) the
    // closing `))`. Nested parens balance normally; quoted strings and
    // backtick substitutions are skipped as opaque units. Returns the body
    // text *without* the closing `))`.
    func readArithmeticBody(startPos: Int) throws -> String {
        var body = ""
        var depth = 0

        while true {
            guard let char = getc(removeQuotedNewline: true) else {
                throw BashSyntaxError.parsing(
                    message: "unclosed `((`",
                    source: source, position: startPos)
            }

            if char == "\\" {
                body.append(char)
                if let next = getc(removeQuotedNewline: false) {
                    body.append(next)
                }
                continue
            }

            if SyntaxClass.isQuoteChar(char) {
                body.append(char)
                delimiters.append(char)
                let inner = try parseMatchedPair(doubleQuote: char, open: char, close: char,
                                                 parsingCommand: char == "`")
                delimiters.removeLast()
                body.append(inner) // includes closing quote
                continue
            }

            if char == "(" {
                depth += 1
                body.append(char)
                continue
            }

            if char == ")" {
                if depth == 0 {
                    if peek() == ")" {
                        _ = getc()
                        return body
                    }
                    throw BashSyntaxError.parsing(
                        message: "expected `))` to close arithmetic",
                        source: source, position: index)
                }
                depth -= 1
                body.append(char)
                continue
            }

            body.append(char)
        }
    }
}
