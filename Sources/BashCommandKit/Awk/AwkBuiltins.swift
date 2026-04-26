import Foundation

/// AWK built-in function dispatch.
enum AwkBuiltins {

    static func call(_ ctx: AwkContext, name: String, args: [AwkExpr]) throws -> AwkValue {
        switch name {
        // strings
        case "length": return try awkLength(ctx, args)
        case "substr": return try awkSubstr(ctx, args)
        case "index": return try awkIndex(ctx, args)
        case "split": return try awkSplit(ctx, args)
        case "sub": return try awkSub(ctx, args, global: false)
        case "gsub": return try awkSub(ctx, args, global: true)
        case "gensub": return try awkGensub(ctx, args)
        case "match": return try awkMatch(ctx, args)
        case "tolower": return try awkTolower(ctx, args)
        case "toupper": return try awkToupper(ctx, args)
        case "sprintf": return try awkSprintf(ctx, args)
        // math
        case "int":
            if args.isEmpty { return .number(0) }
            return .number(try AwkExpressions.eval(ctx, args[0]).asNumber.rounded(.towardZero))
        case "sqrt":
            if args.isEmpty { return .number(0) }
            return .number(sqrt(try AwkExpressions.eval(ctx, args[0]).asNumber))
        case "sin":
            if args.isEmpty { return .number(0) }
            return .number(sin(try AwkExpressions.eval(ctx, args[0]).asNumber))
        case "cos":
            if args.isEmpty { return .number(0) }
            return .number(cos(try AwkExpressions.eval(ctx, args[0]).asNumber))
        case "atan2":
            let y = args.count > 0 ? try AwkExpressions.eval(ctx, args[0]).asNumber : 0
            let x = args.count > 1 ? try AwkExpressions.eval(ctx, args[1]).asNumber : 0
            return .number(atan2(y, x))
        case "log":
            if args.isEmpty { return .number(0) }
            return .number(log(try AwkExpressions.eval(ctx, args[0]).asNumber))
        case "exp":
            if args.isEmpty { return .number(1) }
            return .number(exp(try AwkExpressions.eval(ctx, args[0]).asNumber))
        case "rand":
            return .number(awkRand(ctx))
        case "srand":
            let seed = args.isEmpty ? Double(Int(Date().timeIntervalSince1970)) :
                try AwkExpressions.eval(ctx, args[0]).asNumber
            let prev = ctx.randomState
            ctx.randomState = UInt64(bitPattern: Int64(seed))
            return .number(Double(prev))
        // I/O
        case "close": return .number(0)
        case "fflush": return .number(0)
        case "system":
            throw AwkRuntimeError("system() is disabled in sandboxed environment")
        // time
        case "systime":
            return .number(Date().timeIntervalSince1970.rounded(.down))
        case "mktime":
            return try awkMktime(ctx, args)
        case "strftime":
            return try awkStrftime(ctx, args)
        default:
            // user function?
            if let fn = ctx.functions[name] {
                return try callUserFunction(ctx, fn: fn, args: args)
            }
            throw AwkRuntimeError("unknown function: \(name)")
        }
    }

    // MARK: - User function

    static func callUserFunction(_ ctx: AwkContext, fn: AwkFunction, args: [AwkExpr]) throws -> AwkValue {
        ctx.currentRecursionDepth += 1
        defer { ctx.currentRecursionDepth -= 1 }
        if ctx.currentRecursionDepth > ctx.maxRecursionDepth {
            throw AwkRuntimeError("recursion depth exceeded")
        }

        // Save & restore param-named variables (params are local).
        var savedScalars: [String: AwkValue?] = [:]
        var createdAliases: [String] = []
        for p in fn.params { savedScalars[p] = ctx.vars[p] }

        for (i, p) in fn.params.enumerated() {
            if i < args.count {
                let a = args[i]
                if case .variable(let name) = a {
                    // Scalar OR array — set up an alias so arrays
                    // pass by reference. If the caller used it as a
                    // scalar before, the alias is harmless.
                    ctx.arrayAliases[p] = name
                    createdAliases.append(p)
                }
                let value = try AwkExpressions.eval(ctx, a)
                ctx.vars[p] = value
            } else {
                ctx.vars[p] = .empty
            }
        }

        ctx.hasReturn = false
        ctx.returnValue = .empty
        try AwkStatements.executeBlock(ctx, fn.body)
        let result = ctx.returnValue

        for p in fn.params {
            if let prior = savedScalars[p], let v = prior {
                ctx.vars[p] = v
            } else {
                ctx.vars.removeValue(forKey: p)
            }
        }
        for alias in createdAliases { ctx.arrayAliases.removeValue(forKey: alias) }

        ctx.hasReturn = false
        ctx.returnValue = .empty
        return result
    }

    // MARK: - String builtins

    private static func awkLength(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        if args.isEmpty { return .number(Double(ctx.line.count)) }
        let s = try AwkExpressions.eval(ctx, args[0]).asString
        return .number(Double(s.count))
    }

    private static func awkSubstr(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        guard args.count >= 2 else { return .empty }
        let s = try AwkExpressions.eval(ctx, args[0]).asString
        let start = Int(try AwkExpressions.eval(ctx, args[1]).asNumber.rounded(.towardZero)) - 1
        let chars = Array(s)
        let from = max(0, start)
        if args.count >= 3 {
            let len = Int(try AwkExpressions.eval(ctx, args[2]).asNumber.rounded(.towardZero))
            if len <= 0 || from >= chars.count { return .empty }
            let end = min(chars.count, from + len)
            return .string(String(chars[from..<end]))
        }
        if from >= chars.count { return .empty }
        return .string(String(chars[from...]))
    }

    private static func awkIndex(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        guard args.count >= 2 else { return .number(0) }
        let s = try AwkExpressions.eval(ctx, args[0]).asString
        let t = try AwkExpressions.eval(ctx, args[1]).asString
        if t.isEmpty { return .number(0) }
        if let r = s.range(of: t) {
            return .number(Double(s.distance(from: s.startIndex, to: r.lowerBound) + 1))
        }
        return .number(0)
    }

    private static func awkSplit(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        guard args.count >= 2 else { return .number(0) }
        let s = try AwkExpressions.eval(ctx, args[0]).asString
        guard case .variable(let arrayName) = args[1] else { return .number(0) }

        var fs: String = ctx.FS
        var fsIsRegex = false
        if args.count >= 3 {
            if case .regex(let p) = args[2] {
                fs = p; fsIsRegex = true
            } else {
                fs = try AwkExpressions.eval(ctx, args[2]).asString
            }
        }
        // Reset target array.
        let arr = AwkArray()
        let parts: [String]
        if fs == " " {
            parts = s.split(omittingEmptySubsequences: true,
                           whereSeparator: { $0.isWhitespace }).map { String($0) }
        } else if fsIsRegex || fs.count > 1 {
            if let regex = try? NSRegularExpression(pattern: fs) {
                let nsstr = s as NSString
                var ps: [String] = []
                var lastEnd = 0
                regex.enumerateMatches(in: s, range: NSRange(location: 0, length: nsstr.length)) { m, _, _ in
                    guard let m else { return }
                    ps.append(nsstr.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd)))
                    lastEnd = m.range.location + m.range.length
                }
                ps.append(nsstr.substring(from: lastEnd))
                parts = ps
            } else {
                parts = s.components(separatedBy: fs)
            }
        } else {
            parts = s.components(separatedBy: fs)
        }
        for (i, p) in parts.enumerated() {
            arr[String(i + 1)] = .string(p)
        }
        let resolved = AwkExpressions.resolveArray(ctx, arrayName)
        ctx.arrays[resolved] = arr
        return .number(Double(parts.count))
    }

    private static func awkSub(_ ctx: AwkContext, _ args: [AwkExpr], global: Bool) throws -> AwkValue {
        guard args.count >= 2 else { return .number(0) }
        let pattern = try patternArg(ctx, args[0])
        let replacement = try AwkExpressions.eval(ctx, args[1]).asString
        let (target, write) = targetIO(ctx, args.count >= 3 ? args[2] : nil)
        let cur = target()
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return .number(0)
        }
        let nsstr = cur as NSString
        let fullRange = NSRange(location: 0, length: nsstr.length)
        let matches = regex.matches(in: cur, range: fullRange)
        if matches.isEmpty {
            try write(cur)
            return .number(0)
        }
        var result = ""
        var pos = 0
        var count = 0
        for m in matches {
            count += 1
            if m.range.location > pos {
                result += nsstr.substring(with: NSRange(location: pos, length: m.range.location - pos))
            }
            if !global && count > 1 {
                result += nsstr.substring(with: m.range)
            } else {
                result += expandSubReplacement(replacement, match: m, in: nsstr)
            }
            pos = m.range.location + m.range.length
            if !global { break }
        }
        if pos < nsstr.length {
            result += nsstr.substring(from: pos)
        }
        try write(result)
        return .number(Double(global ? matches.count : 1))
    }

    private static func awkGensub(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        guard args.count >= 3 else { return .empty }
        let pattern = try patternArg(ctx, args[0])
        let replacement = try AwkExpressions.eval(ctx, args[1]).asString
        let how = try AwkExpressions.eval(ctx, args[2]).asString
        let target: String
        if args.count >= 4 {
            target = try AwkExpressions.eval(ctx, args[3]).asString
        } else {
            target = ctx.line
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return .string(target)
        }
        let nsstr = target as NSString
        let fullRange = NSRange(location: 0, length: nsstr.length)
        let matches = regex.matches(in: target, range: fullRange)
        if matches.isEmpty { return .string(target) }
        let isGlobal = how.lowercased() == "g"
        let nth = Int(how) ?? 1
        var result = ""
        var pos = 0
        var count = 0
        for m in matches {
            count += 1
            if m.range.location > pos {
                result += nsstr.substring(with: NSRange(location: pos, length: m.range.location - pos))
            }
            let shouldReplace = isGlobal || count == nth
            if shouldReplace {
                result += expandGensubReplacement(replacement, match: m, in: nsstr)
            } else {
                result += nsstr.substring(with: m.range)
            }
            pos = m.range.location + m.range.length
        }
        if pos < nsstr.length {
            result += nsstr.substring(from: pos)
        }
        return .string(result)
    }

    private static func awkMatch(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        guard args.count >= 2 else {
            ctx.RSTART = 0
            ctx.RLENGTH = -1
            return .number(0)
        }
        let s = try AwkExpressions.eval(ctx, args[0]).asString
        let pattern = try patternArg(ctx, args[1])
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            ctx.RSTART = 0
            ctx.RLENGTH = -1
            return .number(0)
        }
        let nsstr = s as NSString
        if let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: nsstr.length)) {
            ctx.RSTART = m.range.location + 1
            ctx.RLENGTH = m.range.length
            return .number(Double(ctx.RSTART))
        }
        ctx.RSTART = 0
        ctx.RLENGTH = -1
        return .number(0)
    }

    private static func awkTolower(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        if args.isEmpty { return .string("") }
        return .string(try AwkExpressions.eval(ctx, args[0]).asString.lowercased())
    }

    private static func awkToupper(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        if args.isEmpty { return .string("") }
        return .string(try AwkExpressions.eval(ctx, args[0]).asString.uppercased())
    }

    private static func awkSprintf(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        if args.isEmpty { return .string("") }
        let fmt = try AwkExpressions.eval(ctx, args[0]).asString
        var values: [AwkValue] = []
        for i in 1..<args.count {
            values.append(try AwkExpressions.eval(ctx, args[i]))
        }
        return .string(AwkPrintf.format(fmt, values: values))
    }

    // MARK: - Time builtins

    private static func awkMktime(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        guard !args.isEmpty else { return .number(-1) }
        let s = try AwkExpressions.eval(ctx, args[0]).asString
        let parts = s.split(separator: " ").compactMap { Int($0) }
        guard parts.count >= 6 else { return .number(-1) }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        c.hour = parts[3]; c.minute = parts[4]; c.second = parts[5]
        c.timeZone = TimeZone(identifier: "UTC")
        guard let date = Calendar(identifier: .gregorian).date(from: c) else {
            return .number(-1)
        }
        return .number(date.timeIntervalSince1970)
    }

    private static func awkStrftime(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        let fmt = args.isEmpty ? "%a %b %e %H:%M:%S %Z %Y" :
            try AwkExpressions.eval(ctx, args[0]).asString
        let t = args.count > 1 ?
            try AwkExpressions.eval(ctx, args[1]).asNumber :
            Date().timeIntervalSince1970
        let date = Date(timeIntervalSince1970: t)
        return .string(formatDate(date, fmt))
    }

    private static func formatDate(_ date: Date, _ fmt: String) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEEE"
        let dayLong = formatter.string(from: date)
        formatter.dateFormat = "EEE"
        let dayShort = formatter.string(from: date)
        formatter.dateFormat = "MMMM"
        let monthLong = formatter.string(from: date)
        formatter.dateFormat = "MMM"
        let monthShort = formatter.string(from: date)
        var out = ""
        var i = fmt.startIndex
        while i < fmt.endIndex {
            let ch = fmt[i]
            if ch == "%" {
                i = fmt.index(after: i)
                if i >= fmt.endIndex { break }
                switch fmt[i] {
                case "Y": out += String(format: "%04d", c.year ?? 1970)
                case "m": out += String(format: "%02d", c.month ?? 1)
                case "d": out += String(format: "%02d", c.day ?? 1)
                case "H": out += String(format: "%02d", c.hour ?? 0)
                case "M": out += String(format: "%02d", c.minute ?? 0)
                case "S": out += String(format: "%02d", c.second ?? 0)
                case "A": out += dayLong
                case "a": out += dayShort
                case "B": out += monthLong
                case "b", "h": out += monthShort
                case "Z": out += "UTC"
                case "%": out += "%"
                case "e": out += String(format: "%2d", c.day ?? 1)
                default: out.append(fmt[i])
                }
                i = fmt.index(after: i)
            } else {
                out.append(ch)
                i = fmt.index(after: i)
            }
        }
        return out
    }

    // MARK: - Substitute helpers

    private static func patternArg(_ ctx: AwkContext, _ arg: AwkExpr) throws -> String {
        if case .regex(let p) = arg { return p }
        var p = try AwkExpressions.eval(ctx, arg).asString
        if p.hasPrefix("/") && p.hasSuffix("/") && p.count >= 2 {
            p = String(p.dropFirst().dropLast())
        }
        return p
    }

    /// Returns (read-current, write-new) for sub/gsub's optional 3rd
    /// argument: variable, field, or default to $0.
    private static func targetIO(_ ctx: AwkContext, _ arg: AwkExpr?) -> (() -> String, (String) throws -> Void) {
        guard let arg else {
            return ({ ctx.line }, { v in AwkFields.setLine(ctx, v) })
        }
        switch arg {
        case .variable(let name):
            return (
                { (AwkExpressions.getVariable(ctx, name)).asString },
                { v in AwkExpressions.setVariable(ctx, name, .string(v)) }
            )
        case .field(let idxExpr):
            let getIdx: () throws -> Int = {
                Int(try AwkExpressions.eval(ctx, idxExpr).asNumber.rounded(.towardZero))
            }
            return (
                { (try? AwkFields.getField(ctx, getIdx()).asString) ?? "" },
                { v in AwkFields.setField(ctx, try getIdx(), .string(v)) }
            )
        case .arrayAccess(let name, let key):
            return (
                { (try? AwkExpressions.getArrayElement(
                    ctx, name, AwkExpressions.eval(ctx, key).asString).asString) ?? "" },
                { v in
                    let k = try AwkExpressions.eval(ctx, key).asString
                    AwkExpressions.setArrayElement(ctx, name, k, .string(v))
                }
            )
        default:
            return ({ ctx.line }, { v in AwkFields.setLine(ctx, v) })
        }
    }

    private static func expandSubReplacement(_ rep: String, match: NSTextCheckingResult, in nsstr: NSString) -> String {
        var out = ""
        let chars = Array(rep)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "&" { out += "&"; i += 2; continue }
                if n == "\\" { out += "\\"; i += 2; continue }
                out.append(n); i += 2; continue
            }
            if c == "&" {
                out += nsstr.substring(with: match.range)
                i += 1; continue
            }
            out.append(c); i += 1
        }
        return out
    }

    private static func expandGensubReplacement(_ rep: String, match: NSTextCheckingResult, in nsstr: NSString) -> String {
        var out = ""
        let chars = Array(rep)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "&" { out += "&"; i += 2; continue }
                if n == "0" { out += nsstr.substring(with: match.range); i += 2; continue }
                if let d = n.asciiValue, d >= 0x31, d <= 0x39 {
                    let idx = Int(d - 0x30)
                    if idx < match.numberOfRanges {
                        let r = match.range(at: idx)
                        if r.location != NSNotFound {
                            out += nsstr.substring(with: r)
                        }
                    }
                    i += 2; continue
                }
                if n == "n" { out += "\n"; i += 2; continue }
                if n == "t" { out += "\t"; i += 2; continue }
                out.append(n); i += 2; continue
            }
            if c == "&" {
                out += nsstr.substring(with: match.range)
                i += 1; continue
            }
            out.append(c); i += 1
        }
        return out
    }

    // MARK: - Random

    private static func awkRand(_ ctx: AwkContext) -> Double {
        // Linear-congruential generator — gives deterministic
        // sequences for srand(42); enough for AWK's typical usage.
        var s = ctx.randomState
        s = s &* 6364136223846793005 &+ 1442695040888963407
        ctx.randomState = s
        // Return [0,1).
        return Double((s >> 11) & 0x1FFFFFFFFFFFFF) / Double(1 << 53)
    }
}
