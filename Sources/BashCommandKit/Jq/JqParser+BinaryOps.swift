import Foundation

// MARK: - Binary operator precedence chain split out of `JqParser`.

extension JqParser {
    mutating func parseAlt() throws -> JqAST {
        var left = try parseOr()
        while match(.alt) != nil {
            let right = try parseOr()
            left = .binaryOp(.alt, left, right)
        }
        return left
    }

    mutating func parseOr() throws -> JqAST {
        var left = try parseAnd()
        while match(.or) != nil {
            let right = try parseAnd()
            left = .binaryOp(.or, left, right)
        }
        return left
    }

    mutating func parseAnd() throws -> JqAST {
        var left = try parseComparison()
        while match(.and) != nil {
            let right = try parseComparison()
            left = .binaryOp(.and, left, right)
        }
        return left
    }

    mutating func parseComparison() throws -> JqAST {
        let left = try parseAddSub()
        let opMap: [(JqTokenKind, JqBinaryOp)] = [
            (.eq, .eq), (.ne, .ne), (.lt, .lt), (.le, .le), (.gt, .gt), (.ge, .ge)
        ]
        for (kind, oper) in opMap where check(kind) {
            advance()
            let right = try parseAddSub()
            return .binaryOp(oper, left, right)
        }
        return left
    }

    mutating func parseAddSub() throws -> JqAST {
        var left = try parseMulDiv()
        while true {
            if match(.plus) != nil {
                let right = try parseMulDiv()
                left = .binaryOp(.add, left, right)
            } else if match(.minus) != nil {
                let right = try parseMulDiv()
                left = .binaryOp(.sub, left, right)
            } else {
                break
            }
        }
        return left
    }

    mutating func parseMulDiv() throws -> JqAST {
        var left = try parseUnary()
        while true {
            if match(.star) != nil {
                let right = try parseUnary(); left = .binaryOp(.mul, left, right)
            } else if match(.slash) != nil {
                let right = try parseUnary(); left = .binaryOp(.div, left, right)
            } else if match(.percent) != nil {
                let right = try parseUnary(); left = .binaryOp(.mod, left, right)
            } else { break }
        }
        return left
    }

    mutating func parseUnary() throws -> JqAST {
        if match(.minus) != nil {
            let operand = try parseUnary()
            return .unaryOp(.neg, operand)
        }
        return try parsePostfix()
    }
}
