import Foundation

// MARK: - Pattern parsing split out of `JqParser` to keep its body lean.

extension JqParser {
    mutating func parsePattern() throws -> JqPattern {
        if match(.lbracket) != nil {
            var elems: [JqPattern] = []
            if !check(.rbracket) {
                elems.append(try parsePattern())
                while match(.comma) != nil {
                    if check(.rbracket) { break }
                    elems.append(try parsePattern())
                }
            }
            _ = try expect(.rbracket, "Expected ']' after array pattern")
            return .array(elems)
        }
        if match(.lbrace) != nil {
            var fields: [JqPatternField] = []
            if !check(.rbrace) {
                fields.append(try parsePatternField())
                while match(.comma) != nil {
                    if check(.rbrace) { break }
                    fields.append(try parsePatternField())
                }
            }
            _ = try expect(.rbrace, "Expected '}' after object pattern")
            return .object(fields)
        }
        // simple variable
        let tok = peek()
        if case .variable(let name) = tok.kind {
            advance()
            return .variable(name)
        }
        throw JqError("jq: parse error: Expected variable name in pattern at position \(tok.pos)")
    }

    mutating func parsePatternField() throws -> JqPatternField {
        if match(.lparen) != nil {
            let keyExpr = try parseExpr()
            _ = try expect(.rparen, "Expected ')' after computed key")
            _ = try expect(.colon, "Expected ':' after computed key")
            let pattern = try parsePattern()
            return JqPatternField(key: .computed(keyExpr), pattern: pattern)
        }
        let tok = peek()
        // $name shorthand: {$foo} == {foo: $foo}; {$foo: pattern} ==
        // {foo: pattern, also bind $foo to value}
        if case .variable(let varName) = tok.kind {
            advance()
            if match(.colon) != nil {
                let pat = try parsePattern()
                return JqPatternField(key: .literal(String(varName.dropFirst())),
                                      pattern: pat,
                                      keyVar: varName)
            }
            return JqPatternField(key: .literal(String(varName.dropFirst())),
                                  pattern: .variable(varName))
        }
        // key (identifier / keyword) optionally followed by ': pattern'
        if let key = identLike(tok) {
            advance()
            if match(.colon) != nil {
                let pat = try parsePattern()
                return JqPatternField(key: .literal(key), pattern: pat)
            }
            return JqPatternField(key: .literal(key), pattern: .variable("$\(key)"))
        }
        throw JqError("jq: parse error: Expected field name in object pattern at position \(tok.pos)")
    }
}
