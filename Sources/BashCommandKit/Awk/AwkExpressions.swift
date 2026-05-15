import Foundation

/// AWK expression evaluator. Synchronous — file I/O for `getline` is
/// served from a per-context cache that the interpreter pre-populates.
enum AwkExpressions {

    // swiftlint:disable:next cyclomatic_complexity - AWK expression dispatch is inherently wide
    static func eval(_ ctx: AwkContext, _ expr: AwkExpr) throws -> AwkValue {
        switch expr {
        case .number(let num):
            return .number(num)
        case .string(let str):
            return .string(str)
        case .regex(let pat):
            // A bare regex in expression context matches against $0.
            return .number(matchRegex(pat, ctx.line) ? 1 : 0)
        case .field(let idx):
            let fieldIdx = Int(try eval(ctx, idx).asNumber.rounded(.towardZero))
            return AwkFields.getField(ctx, fieldIdx)
        case .variable(let name):
            return getVariable(ctx, name)
        case .arrayAccess(let name, let key):
            let keyStr = try eval(ctx, key).asString
            return getArrayElement(ctx, name, keyStr)
        case .binary(let oper, let lhs, let rhs):
            return try evalBinary(ctx, oper, lhs, rhs)
        case .unary(let oper, let operand):
            let value = try eval(ctx, operand)
            switch oper {
            case .not: return .number(value.isTruthy ? 0 : 1)
            case .neg: return .number(-value.asNumber)
            case .pos: return .number(+value.asNumber)
            }
        case .ternary(let cond, let then, let els):
            return try eval(ctx, cond).isTruthy ? try eval(ctx, then) : try eval(ctx, els)
        case .call(let name, let args):
            return try AwkBuiltins.call(ctx, name: name, args: args)
        case .assignment(let oper, let target, let value):
            return try evalAssignment(ctx, oper, target, value)
        case .preIncrement(let lval): return try evalIncDec(ctx, lval, +1, returnNew: true)
        case .preDecrement(let lval): return try evalIncDec(ctx, lval, -1, returnNew: true)
        case .postIncrement(let lval): return try evalIncDec(ctx, lval, +1, returnNew: false)
        case .postDecrement(let lval): return try evalIncDec(ctx, lval, -1, returnNew: false)
        case .inExpr(let key, let arrayName):
            let keyStr = try evalArrayKey(ctx, key)
            return .number(hasArrayElement(ctx, arrayName, keyStr) ? 1 : 0)
        case .getline(let value, let file, let cmd):
            return try AwkGetline.run(ctx, variable: value, file: file, command: cmd)
        case .tuple(let elems):
            // Comma operator: evaluate all, return last.
            var last: AwkValue = .empty
            for elem in elems { last = try eval(ctx, elem) }
            return last
        }
    }

    // MARK: - Variables / arrays

    // swiftlint:disable:next cyclomatic_complexity - dispatch over AWK special variable names
    static func getVariable(_ ctx: AwkContext, _ name: String) -> AwkValue {
        switch name {
        case "FS": return .string(ctx.FS)
        case "OFS": return .string(ctx.OFS)
        case "ORS": return .string(ctx.ORS)
        case "OFMT": return .string(ctx.OFMT)
        case "NR": return .number(Double(ctx.NR))
        case "NF": return .number(Double(ctx.NF))
        case "FNR": return .number(Double(ctx.FNR))
        case "FILENAME": return .string(ctx.FILENAME)
        case "RSTART": return .number(Double(ctx.RSTART))
        case "RLENGTH": return .number(Double(ctx.RLENGTH))
        case "SUBSEP": return .string(ctx.SUBSEP)
        case "ARGC": return .number(Double(ctx.ARGC))
        default: return ctx.vars[name] ?? .empty
        }
    }

    // swiftlint:disable:next cyclomatic_complexity - dispatch over AWK special variable names
    static func setVariable(_ ctx: AwkContext, _ name: String, _ value: AwkValue) {
        switch name {
        case "FS": ctx.FS = value.asString
        case "OFS": ctx.OFS = value.asString
        case "ORS": ctx.ORS = value.asString
        case "OFMT": ctx.OFMT = value.asString
        case "NR": ctx.NR = Int(value.asNumber)
        case "NF": AwkFields.setNF(ctx, Int(value.asNumber))
        case "FNR": ctx.FNR = Int(value.asNumber)
        case "FILENAME": ctx.FILENAME = value.asString
        case "RSTART": ctx.RSTART = Int(value.asNumber)
        case "RLENGTH": ctx.RLENGTH = Int(value.asNumber)
        case "SUBSEP": ctx.SUBSEP = value.asString
        default: ctx.vars[name] = value
        }
    }

    // Array operations live in `AwkExpressions+Arrays.swift`.

    // MARK: - Binary

    // swiftlint:disable:next cyclomatic_complexity - arithmetic op dispatch
    static func evalBinary(_ ctx: AwkContext, _ oper: AwkBinaryOp,
                           _ lhs: AwkExpr, _ rhs: AwkExpr) throws -> AwkValue {
        // Short-circuit
        if oper == .and {
            let lhsVal = try eval(ctx, lhs)
            if !lhsVal.isTruthy { return .number(0) }
            return .number(try eval(ctx, rhs).isTruthy ? 1 : 0)
        }
        if oper == .or {
            let lhsVal = try eval(ctx, lhs)
            if lhsVal.isTruthy { return .number(1) }
            return .number(try eval(ctx, rhs).isTruthy ? 1 : 0)
        }
        // Match operators — RHS may be a literal regex.
        if oper == .match || oper == .notMatch {
            let lhsVal = try eval(ctx, lhs)
            let pat: String
            if case .regex(let parsedPat) = rhs { pat = parsedPat } else { pat = try eval(ctx, rhs).asString }
            let matches = matchRegex(pat, lhsVal.asString)
            let positive = (oper == .match) == matches
            return .number(positive ? 1 : 0)
        }
        let lhsVal = try eval(ctx, lhs)
        let rhsVal = try eval(ctx, rhs)
        if oper == .concat { return .string(lhsVal.asString + rhsVal.asString) }
        if isComparison(oper) {
            return .number(applyComparison(oper, lhsVal, rhsVal) ? 1 : 0)
        }
        let lhsNum = lhsVal.asNumber, rhsNum = rhsVal.asNumber
        switch oper {
        case .add: return .number(lhsNum + rhsNum)
        case .sub: return .number(lhsNum - rhsNum)
        case .mul: return .number(lhsNum * rhsNum)
        case .div:
            if rhsNum == 0 { throw AwkRuntimeError("division by zero") }
            return .number(lhsNum / rhsNum)
        case .mod:
            if rhsNum == 0 { throw AwkRuntimeError("division by zero in %") }
            return .number(lhsNum.truncatingRemainder(dividingBy: rhsNum))
        case .pow: return .number(pow(lhsNum, rhsNum))
        default: return .empty
        }
    }

    static func isComparison(_ oper: AwkBinaryOp) -> Bool {
        switch oper {
        case .eq, .ne, .lt, .le, .gt, .ge: return true
        default: return false
        }
    }

    // swiftlint:disable:next cyclomatic_complexity - 6 comparison ops, evaluated twice
    static func applyComparison(_ oper: AwkBinaryOp, _ lhs: AwkValue, _ rhs: AwkValue) -> Bool {
        let lhsNumeric = lhs.looksLikeNumber, rhsNumeric = rhs.looksLikeNumber
        if lhsNumeric && rhsNumeric {
            let lhsNum = lhs.asNumber, rhsNum = rhs.asNumber
            switch oper {
            case .lt: return lhsNum < rhsNum
            case .le: return lhsNum <= rhsNum
            case .gt: return lhsNum > rhsNum
            case .ge: return lhsNum >= rhsNum
            case .eq: return lhsNum == rhsNum
            case .ne: return lhsNum != rhsNum
            default: return false
            }
        }
        let lhsStr = lhs.asString, rhsStr = rhs.asString
        switch oper {
        case .lt: return lhsStr < rhsStr
        case .le: return lhsStr <= rhsStr
        case .gt: return lhsStr > rhsStr
        case .ge: return lhsStr >= rhsStr
        case .eq: return lhsStr == rhsStr
        case .ne: return lhsStr != rhsStr
        default: return false
        }
    }

    // MARK: - Assignments

    static func evalAssignment(_ ctx: AwkContext, _ oper: AwkAssignOp,
                               _ target: AwkLValue, _ value: AwkExpr) throws -> AwkValue {
        let newVal = try eval(ctx, value)
        let final: AwkValue
        if oper == .assign {
            final = newVal
        } else {
            let cur = try readLValue(ctx, target)
            let lhsNum = cur.asNumber, rhsNum = newVal.asNumber
            switch oper {
            case .addAssign: final = .number(lhsNum + rhsNum)
            case .subAssign: final = .number(lhsNum - rhsNum)
            case .mulAssign: final = .number(lhsNum * rhsNum)
            case .divAssign:
                if rhsNum == 0 { throw AwkRuntimeError("division by zero in /=") }
                final = .number(lhsNum / rhsNum)
            case .modAssign:
                if rhsNum == 0 { throw AwkRuntimeError("division by zero in %=") }
                final = .number(lhsNum.truncatingRemainder(dividingBy: rhsNum))
            case .powAssign: final = .number(pow(lhsNum, rhsNum))
            default: final = newVal
            }
        }
        try writeLValue(ctx, target, final)
        return final
    }

    static func readLValue(_ ctx: AwkContext, _ lval: AwkLValue) throws -> AwkValue {
        switch lval {
        case .variable(let name): return getVariable(ctx, name)
        case .field(let idx):
            let fieldIdx = Int(try eval(ctx, idx).asNumber.rounded(.towardZero))
            return AwkFields.getField(ctx, fieldIdx)
        case .arrayAccess(let name, let key):
            return getArrayElement(ctx, name, try eval(ctx, key).asString)
        }
    }

    static func writeLValue(_ ctx: AwkContext, _ lval: AwkLValue, _ value: AwkValue) throws {
        switch lval {
        case .variable(let name): setVariable(ctx, name, value)
        case .field(let idx):
            let fieldIdx = Int(try eval(ctx, idx).asNumber.rounded(.towardZero))
            AwkFields.setField(ctx, fieldIdx, value)
        case .arrayAccess(let name, let key):
            setArrayElement(ctx, name, try eval(ctx, key).asString, value)
        }
    }

    static func evalIncDec(_ ctx: AwkContext, _ lval: AwkLValue, _ delta: Double,
                           returnNew: Bool) throws -> AwkValue {
        let cur = try readLValue(ctx, lval).asNumber
        let new = cur + delta
        try writeLValue(ctx, lval, .number(new))
        return .number(returnNew ? new : cur)
    }

    // MARK: - Regex

    static func matchRegex(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let nsstr = text as NSString
        return regex.firstMatch(in: text,
                                range: NSRange(location: 0, length: nsstr.length)) != nil
    }
}
