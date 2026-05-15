import Foundation

// MARK: - Helpers split out of `JqParser` to keep its body lean.

extension JqParser {
    // swiftlint:disable:next cyclomatic_complexity - keyword/ident dispatch
    func identLike(_ tok: JqToken) -> String? {
        switch tok.kind {
        case .ident(let str): return str
        case .and: return "and"
        case .or: return "or"
        case .not_: return "not"
        case .if_: return "if"
        case .then: return "then"
        case .elif: return "elif"
        case .else_: return "else"
        case .end: return "end"
        case .as_: return "as"
        case .try_: return "try"
        case .catch_: return "catch"
        case .true_: return "true"
        case .false_: return "false"
        case .null: return "null"
        case .reduce: return "reduce"
        case .foreach: return "foreach"
        case .label: return "label"
        case .break_: return "break"
        case .def: return "def"
        default: return nil
        }
    }

    /// Return the field-name string from a token at position
    /// `dotPos + 1`. Identifiers, jq keywords, and quoted strings all
    /// count.
    func fieldName(from tok: JqToken, dotPos: Int) -> String? {
        if case .string(let str) = tok.kind { return str }
        return identLike(tok)
    }

    // Parse a string literal whose body may contain `\(expr)`
    // interpolations. The lexer preserves `\(` literally so we
    // re-tokenize the inner expression here.
    // swiftlint:disable:next cyclomatic_complexity - nested escape scanner
    static func parseInterpolation(_ raw: String) -> JqAST {
        if !raw.contains("\\(") {
            return .literal(.string(raw))
        }
        var parts: [JqStringPart] = []
        var current = ""
        let chars = Array(raw)
        var idx = 0
        while idx < chars.count {
            if chars[idx] == "\\" && idx + 1 < chars.count && chars[idx + 1] == "(" {
                if !current.isEmpty {
                    parts.append(.literal(current))
                    current = ""
                }
                idx += 2
                var depth = 1
                var inner = ""
                while idx < chars.count && depth > 0 {
                    if chars[idx] == "(" { depth += 1 } else if chars[idx] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    inner.append(chars[idx])
                    idx += 1
                }
                if idx < chars.count { idx += 1 }  // consume ')'
                if let ast = try? JqParser.parse(inner) {
                    parts.append(.interp(ast))
                }
            } else {
                current.append(chars[idx])
                idx += 1
            }
        }
        if !current.isEmpty { parts.append(.literal(current)) }
        return .stringInterp(parts)
    }
}
