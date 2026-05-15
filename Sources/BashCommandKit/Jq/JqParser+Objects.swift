import Foundation

// MARK: - Object construction parsing split out of `JqParser`.

extension JqParser {
    mutating func parseObjectConstruction() throws -> JqAST {
        var entries: [JqObjectEntry] = []
        if !check(.rbrace) {
            repeat {
                entries.append(try parseObjectEntry())
            } while match(.comma) != nil
        }
        _ = try expect(.rbrace, "Expected '}'")
        return .object(entries)
    }

    mutating func parseObjectEntry() throws -> JqObjectEntry {
        // (expr): value
        if match(.lparen) != nil {
            let keyExpr = try parseExpr()
            _ = try expect(.rparen, "Expected ')'")
            _ = try expect(.colon, "Expected ':'")
            let value = try parseObjectValue()
            return JqObjectEntry(key: .computed(keyExpr), value: value)
        }
        let tok = peek()
        // "string": value
        if case .string(let str) = tok.kind {
            advance()
            _ = try expect(.colon, "Expected ':'")
            let value = try parseObjectValue()
            return JqObjectEntry(key: .literal(str), value: value)
        }
        // $foo shorthand: {$foo} == {foo: $foo}
        if case .variable(let varName) = tok.kind {
            advance()
            if match(.colon) != nil {
                let value = try parseObjectValue()
                return JqObjectEntry(key: .literal(String(varName.dropFirst())), value: value)
            }
            // shorthand: $foo means foo: $foo
            return JqObjectEntry(key: .literal(String(varName.dropFirst())),
                                 value: .varRef(varName))
        }
        // ident or keyword as key
        if let key = identLike(tok) {
            advance()
            if match(.colon) != nil {
                let value = try parseObjectValue()
                return JqObjectEntry(key: .literal(key), value: value)
            }
            // shorthand {key} == {key: .key}
            return JqObjectEntry(key: .literal(key),
                                 value: .field(name: key, base: nil))
        }
        throw JqError("jq: parse error: Expected object key at position \(tok.pos)")
    }

    /// Object values allow pipes but stop at comma — comma separates
    /// entries, not pipeline elements.
    mutating func parseObjectValue() throws -> JqAST {
        var left = try parseVarBind()
        while match(.pipe) != nil {
            let right = try parseVarBind()
            left = .pipe(left, right)
        }
        return left
    }
}
