import Foundation

extension BcCalculator.Parser {

    // Precedence climbing — bc grammar:
    //  or > and > comparison > add/sub > mul/div/mod > pow > unary > primary
    mutating func parseExpr() throws -> Double { try parseOr() }

    mutating func parseOr() throws -> Double {
        var lhs = try parseAnd()
        while peekStr2() == "||" {
            pos += 2; skipWS()
            let rhs = try parseAnd()
            lhs = (lhs != 0 || rhs != 0) ? 1 : 0
        }
        return lhs
    }

    mutating func parseAnd() throws -> Double {
        var lhs = try parseComparison()
        while peekStr2() == "&&" {
            pos += 2; skipWS()
            let rhs = try parseComparison()
            lhs = (lhs != 0 && rhs != 0) ? 1 : 0
        }
        return lhs
    }

    mutating func parseComparison() throws -> Double {
        let lhs = try parseAddSub()
        if let cmpOp = peekCmpOp() {
            pos += cmpOp.count; skipWS()
            let rhs = try parseAddSub()
            switch cmpOp {
            case "==": return lhs == rhs ? 1 : 0
            case "!=": return lhs != rhs ? 1 : 0
            case "<=": return lhs <= rhs ? 1 : 0
            case ">=": return lhs >= rhs ? 1 : 0
            case "<":  return lhs < rhs ? 1 : 0
            case ">":  return lhs > rhs ? 1 : 0
            default:   return lhs
            }
        }
        return lhs
    }

    mutating func parseAddSub() throws -> Double {
        var lhs = try parseMulDiv()
        while pos < chars.count, chars[pos] == "+" || chars[pos] == "-" {
            let addOp = chars[pos]; pos += 1; skipWS()
            let rhs = try parseMulDiv()
            lhs = addOp == "+" ? lhs + rhs : lhs - rhs
        }
        return lhs
    }

    mutating func parseMulDiv() throws -> Double {
        var lhs = try parsePow()
        while pos < chars.count,
              chars[pos] == "*" || chars[pos] == "/" || chars[pos] == "%" {
            let mulOp = chars[pos]; pos += 1; skipWS()
            let rhs = try parsePow()
            if (mulOp == "/" || mulOp == "%") && rhs == 0 {
                throw BcCalculator.Error("divide by zero")
            }
            switch mulOp {
            case "*": lhs *= rhs
            case "/": lhs /= rhs
            default:  lhs = lhs.truncatingRemainder(dividingBy: rhs)
            }
        }
        return lhs
    }

    mutating func parsePow() throws -> Double {
        let base = try parseUnary()
        if pos < chars.count, chars[pos] == "^" {
            pos += 1; skipWS()
            let exp = try parsePow()  // right-associative
            return pow(base, exp)
        }
        return base
    }

    mutating func parseUnary() throws -> Double {
        if pos < chars.count, chars[pos] == "-" {
            pos += 1; skipWS()
            return -(try parseUnary())
        }
        if pos < chars.count, chars[pos] == "+" {
            pos += 1; skipWS()
            return try parseUnary()
        }
        if pos < chars.count, chars[pos] == "!" {
            pos += 1; skipWS()
            return try parseUnary() == 0 ? 1 : 0
        }
        return try parsePrimary()
    }

    // Bc primary: parentheses / number / identifier (variable, function
    // call, or `scale`). The branches are tightly bound to a single
    // `pos` advance and a single ctx.vars lookup; per-branch helpers
    // would just add ceremony.
    // swiftlint:disable:next cyclomatic_complexity
    mutating func parsePrimary() throws -> Double {
        skipWS()
        guard pos < chars.count else {
            throw BcCalculator.Error("syntax error: unexpected end")
        }
        if chars[pos] == "(" {
            pos += 1; skipWS()
            let value = try parseExpr()
            skipWS()
            guard pos < chars.count, chars[pos] == ")" else {
                throw BcCalculator.Error("missing `)`")
            }
            pos += 1; skipWS()
            return value
        }
        if chars[pos].isNumber || chars[pos] == "." {
            return parseNumber()
        }
        if isIdentChar(chars[pos], first: true) {
            let start = pos
            while pos < chars.count, isIdentChar(chars[pos], first: false) { pos += 1 }
            let name = String(chars[start..<pos])
            skipWS()
            if pos < chars.count, chars[pos] == "(" {
                pos += 1; skipWS()
                var args: [Double] = []
                if pos < chars.count, chars[pos] != ")" {
                    args.append(try parseExpr())
                    while pos < chars.count, chars[pos] == "," {
                        pos += 1; skipWS()
                        args.append(try parseExpr())
                    }
                }
                skipWS()
                guard pos < chars.count, chars[pos] == ")" else {
                    throw BcCalculator.Error("missing `)`")
                }
                pos += 1; skipWS()
                return try callBuiltin(name: name, args: args)
            }
            if name == "scale" { return Double(ctx.scale) }
            return ctx.vars[name] ?? 0
        }
        throw BcCalculator.Error("unexpected character `\(chars[pos])`")
    }

    mutating func parseNumber() -> Double {
        let start = pos
        while pos < chars.count, chars[pos].isNumber || chars[pos] == "." { pos += 1 }
        // Optional e/E exponent.
        if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
            pos += 1
            if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { pos += 1 }
            while pos < chars.count, chars[pos].isNumber { pos += 1 }
        }
        let str = String(chars[start..<pos])
        skipWS()
        return Double(str) ?? 0
    }

    // Builtin dispatch: per-name switch over bc's math/utility builtins.
    // The switch is the table — splitting per-arm helpers would just
    // scatter eight one-liners.
    // swiftlint:disable:next cyclomatic_complexity
    func callBuiltin(name: String, args: [Double]) throws -> Double {
        switch name {
        case "sqrt":
            guard args.count == 1 else { throw BcCalculator.Error("sqrt requires 1 argument") }
            return args[0].squareRoot()
        case "length":
            guard args.count == 1 else { throw BcCalculator.Error("length requires 1 argument") }
            return Double(String(Int64(args[0].rounded(.towardZero))).count)
        case "scale":
            guard args.count == 1 else { throw BcCalculator.Error("scale requires 1 argument") }
            let str = "\(args[0])"
            if let dot = str.firstIndex(of: ".") {
                return Double(str.distance(from: str.index(after: dot), to: str.endIndex))
            }
            return 0
        case "s":   return sin(args[0])
        case "c":   return cos(args[0])
        case "a":   return atan(args[0])
        case "l":   return log(args[0])
        case "e":   return exp(args[0])
        case "abs": return abs(args[0])
        default:
            throw BcCalculator.Error("unknown function: \(name)")
        }
    }
}
