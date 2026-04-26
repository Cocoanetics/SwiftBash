import Foundation

/// AWK expression evaluator. Synchronous — file I/O for `getline` is
/// served from a per-context cache that the interpreter pre-populates.
enum AwkExpressions {

    static func eval(_ ctx: AwkContext, _ expr: AwkExpr) throws -> AwkValue {
        switch expr {
        case .number(let n):
            return .number(n)
        case .string(let s):
            return .string(s)
        case .regex(let pat):
            // A bare regex in expression context matches against $0.
            return .number(matchRegex(pat, ctx.line) ? 1 : 0)
        case .field(let idx):
            let i = Int(try eval(ctx, idx).asNumber.rounded(.towardZero))
            return AwkFields.getField(ctx, i)
        case .variable(let name):
            return getVariable(ctx, name)
        case .arrayAccess(let name, let key):
            let k = try eval(ctx, key).asString
            return getArrayElement(ctx, name, k)
        case .binary(let op, let l, let r):
            return try evalBinary(ctx, op, l, r)
        case .unary(let op, let operand):
            let v = try eval(ctx, operand)
            switch op {
            case .not: return .number(v.isTruthy ? 0 : 1)
            case .neg: return .number(-v.asNumber)
            case .pos: return .number(+v.asNumber)
            }
        case .ternary(let c, let t, let e):
            return try eval(ctx, c).isTruthy ? try eval(ctx, t) : try eval(ctx, e)
        case .call(let name, let args):
            return try AwkBuiltins.call(ctx, name: name, args: args)
        case .assignment(let op, let target, let value):
            return try evalAssignment(ctx, op, target, value)
        case .preIncrement(let lv): return try evalIncDec(ctx, lv, +1, returnNew: true)
        case .preDecrement(let lv): return try evalIncDec(ctx, lv, -1, returnNew: true)
        case .postIncrement(let lv): return try evalIncDec(ctx, lv, +1, returnNew: false)
        case .postDecrement(let lv): return try evalIncDec(ctx, lv, -1, returnNew: false)
        case .inExpr(let key, let arrayName):
            let k = try evalArrayKey(ctx, key)
            return .number(hasArrayElement(ctx, arrayName, k) ? 1 : 0)
        case .getline(let v, let file, let cmd):
            return try AwkGetline.run(ctx, variable: v, file: file, command: cmd)
        case .tuple(let elems):
            // Comma operator: evaluate all, return last.
            var last: AwkValue = .empty
            for e in elems { last = try eval(ctx, e) }
            return last
        }
    }

    // MARK: - Variables / arrays

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

    static func resolveArray(_ ctx: AwkContext, _ name: String) -> String {
        // Follow alias chain (for function param pass-by-reference).
        var resolved = name
        var seen = Set<String>()
        while let alias = ctx.arrayAliases[resolved], !seen.contains(resolved) {
            seen.insert(resolved)
            resolved = alias
        }
        return resolved
    }

    static func getArrayElement(_ ctx: AwkContext, _ name: String, _ key: String) -> AwkValue {
        if name == "ARGV" { return ctx.ARGV[key] ?? .empty }
        if name == "ENVIRON" { return ctx.ENVIRON[key] ?? .empty }
        let resolved = resolveArray(ctx, name)
        return ctx.arrays[resolved]?[key] ?? .empty
    }

    static func setArrayElement(_ ctx: AwkContext, _ name: String, _ key: String, _ value: AwkValue) {
        let resolved = resolveArray(ctx, name)
        if ctx.arrays[resolved] == nil { ctx.arrays[resolved] = AwkArray() }
        ctx.arrays[resolved]![key] = value
    }

    static func hasArrayElement(_ ctx: AwkContext, _ name: String, _ key: String) -> Bool {
        if name == "ARGV" { return ctx.ARGV[key] != nil }
        if name == "ENVIRON" { return ctx.ENVIRON[key] != nil }
        let resolved = resolveArray(ctx, name)
        return ctx.arrays[resolved]?[key] != nil
    }

    static func deleteArrayElement(_ ctx: AwkContext, _ name: String, _ key: String) {
        let resolved = resolveArray(ctx, name)
        ctx.arrays[resolved]?.remove(key)
    }

    static func deleteArray(_ ctx: AwkContext, _ name: String) {
        let resolved = resolveArray(ctx, name)
        ctx.arrays[resolved]?.clear()
    }

    /// `(i, j) in arr` joins the tuple parts with SUBSEP.
    static func evalArrayKey(_ ctx: AwkContext, _ key: AwkExpr) throws -> String {
        if case .tuple(let elems) = key {
            var parts: [String] = []
            for e in elems { parts.append(try eval(ctx, e).asString) }
            return parts.joined(separator: ctx.SUBSEP)
        }
        return try eval(ctx, key).asString
    }

    // MARK: - Binary

    static func evalBinary(_ ctx: AwkContext, _ op: AwkBinaryOp,
                           _ l: AwkExpr, _ r: AwkExpr) throws -> AwkValue {
        // Short-circuit
        if op == .and {
            let lv = try eval(ctx, l)
            if !lv.isTruthy { return .number(0) }
            return .number(try eval(ctx, r).isTruthy ? 1 : 0)
        }
        if op == .or {
            let lv = try eval(ctx, l)
            if lv.isTruthy { return .number(1) }
            return .number(try eval(ctx, r).isTruthy ? 1 : 0)
        }
        // Match operators — RHS may be a literal regex.
        if op == .match || op == .notMatch {
            let lv = try eval(ctx, l)
            let pat: String
            if case .regex(let p) = r { pat = p }
            else { pat = try eval(ctx, r).asString }
            let matches = matchRegex(pat, lv.asString)
            let positive = (op == .match) == matches
            return .number(positive ? 1 : 0)
        }
        let lv = try eval(ctx, l)
        let rv = try eval(ctx, r)
        if op == .concat { return .string(lv.asString + rv.asString) }
        if isComparison(op) {
            return .number(applyComparison(op, lv, rv) ? 1 : 0)
        }
        let ln = lv.asNumber, rn = rv.asNumber
        switch op {
        case .add: return .number(ln + rn)
        case .sub: return .number(ln - rn)
        case .mul: return .number(ln * rn)
        case .div:
            if rn == 0 { throw AwkRuntimeError("division by zero") }
            return .number(ln / rn)
        case .mod:
            if rn == 0 { throw AwkRuntimeError("division by zero in %") }
            return .number(ln.truncatingRemainder(dividingBy: rn))
        case .pow: return .number(pow(ln, rn))
        default: return .empty
        }
    }

    static func isComparison(_ op: AwkBinaryOp) -> Bool {
        switch op {
        case .eq, .ne, .lt, .le, .gt, .ge: return true
        default: return false
        }
    }

    static func applyComparison(_ op: AwkBinaryOp, _ l: AwkValue, _ r: AwkValue) -> Bool {
        let ln = l.looksLikeNumber, rn = r.looksLikeNumber
        if ln && rn {
            let a = l.asNumber, b = r.asNumber
            switch op {
            case .lt: return a < b
            case .le: return a <= b
            case .gt: return a > b
            case .ge: return a >= b
            case .eq: return a == b
            case .ne: return a != b
            default: return false
            }
        }
        let a = l.asString, b = r.asString
        switch op {
        case .lt: return a < b
        case .le: return a <= b
        case .gt: return a > b
        case .ge: return a >= b
        case .eq: return a == b
        case .ne: return a != b
        default: return false
        }
    }

    // MARK: - Assignments

    static func evalAssignment(_ ctx: AwkContext, _ op: AwkAssignOp,
                               _ target: AwkLValue, _ value: AwkExpr) throws -> AwkValue {
        let newVal = try eval(ctx, value)
        let final: AwkValue
        if op == .assign {
            final = newVal
        } else {
            let cur = try readLValue(ctx, target)
            let a = cur.asNumber, b = newVal.asNumber
            switch op {
            case .addAssign: final = .number(a + b)
            case .subAssign: final = .number(a - b)
            case .mulAssign: final = .number(a * b)
            case .divAssign:
                if b == 0 { throw AwkRuntimeError("division by zero in /=") }
                final = .number(a / b)
            case .modAssign:
                if b == 0 { throw AwkRuntimeError("division by zero in %=") }
                final = .number(a.truncatingRemainder(dividingBy: b))
            case .powAssign: final = .number(pow(a, b))
            default: final = newVal
            }
        }
        try writeLValue(ctx, target, final)
        return final
    }

    static func readLValue(_ ctx: AwkContext, _ lv: AwkLValue) throws -> AwkValue {
        switch lv {
        case .variable(let n): return getVariable(ctx, n)
        case .field(let idx):
            let i = Int(try eval(ctx, idx).asNumber.rounded(.towardZero))
            return AwkFields.getField(ctx, i)
        case .arrayAccess(let n, let k):
            return getArrayElement(ctx, n, try eval(ctx, k).asString)
        }
    }

    static func writeLValue(_ ctx: AwkContext, _ lv: AwkLValue, _ value: AwkValue) throws {
        switch lv {
        case .variable(let n): setVariable(ctx, n, value)
        case .field(let idx):
            let i = Int(try eval(ctx, idx).asNumber.rounded(.towardZero))
            AwkFields.setField(ctx, i, value)
        case .arrayAccess(let n, let k):
            setArrayElement(ctx, n, try eval(ctx, k).asString, value)
        }
    }

    static func evalIncDec(_ ctx: AwkContext, _ lv: AwkLValue, _ delta: Double,
                           returnNew: Bool) throws -> AwkValue {
        let cur = try readLValue(ctx, lv).asNumber
        let new = cur + delta
        try writeLValue(ctx, lv, .number(new))
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
