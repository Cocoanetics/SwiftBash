// swiftlint:disable file_length
import Foundation

// AWK built-in function dispatch.
// swiftlint:disable:next type_body_length
enum AwkBuiltins {

    // Function-name → handler dispatch table; per-name cases keep each
    // body a single line so splitting buys nothing.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
            let yArg = !args.isEmpty ? try AwkExpressions.eval(ctx, args[0]).asNumber : 0
            let xArg = args.count > 1 ? try AwkExpressions.eval(ctx, args[1]).asNumber : 0
            return .number(atan2(yArg, xArg))
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
            if let function = ctx.functions[name] {
                return try callUserFunction(ctx, function: function, args: args)
            }
            throw AwkRuntimeError("unknown function: \(name)")
        }
    }

    // MARK: - User function

    static func callUserFunction(_ ctx: AwkContext,
                                 function: AwkFunction,
                                 args: [AwkExpr]) throws -> AwkValue {
        ctx.currentRecursionDepth += 1
        defer { ctx.currentRecursionDepth -= 1 }
        if ctx.currentRecursionDepth > ctx.maxRecursionDepth {
            throw AwkRuntimeError("recursion depth exceeded")
        }

        // Save & restore param-named variables (params are local).
        var savedScalars: [String: AwkValue?] = [:]
        var createdAliases: [String] = []
        for param in function.params { savedScalars[param] = ctx.vars[param] }

        for (idx, param) in function.params.enumerated() {
            if idx < args.count {
                let arg = args[idx]
                if case .variable(let name) = arg {
                    // Scalar OR array — set up an alias so arrays
                    // pass by reference. If the caller used it as a
                    // scalar before, the alias is harmless.
                    ctx.arrayAliases[param] = name
                    createdAliases.append(param)
                }
                let value = try AwkExpressions.eval(ctx, arg)
                ctx.vars[param] = value
            } else {
                ctx.vars[param] = .empty
            }
        }

        ctx.hasReturn = false
        ctx.returnValue = .empty
        try AwkStatements.executeBlock(ctx, function.body)
        let result = ctx.returnValue

        for param in function.params {
            if let prior = savedScalars[param], let value = prior {
                ctx.vars[param] = value
            } else {
                ctx.vars.removeValue(forKey: param)
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
        let value = try AwkExpressions.eval(ctx, args[0]).asString
        return .number(Double(value.count))
    }

    private static func awkSubstr(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        guard args.count >= 2 else { return .empty }
        let source = try AwkExpressions.eval(ctx, args[0]).asString
        let start = Int(try AwkExpressions.eval(ctx, args[1]).asNumber.rounded(.towardZero)) - 1
        let chars = Array(source)
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
        let source = try AwkExpressions.eval(ctx, args[0]).asString
        let needle = try AwkExpressions.eval(ctx, args[1]).asString
        if needle.isEmpty { return .number(0) }
        if let found = source.range(of: needle) {
            return .number(Double(source.distance(from: source.startIndex, to: found.lowerBound) + 1))
        }
        return .number(0)
    }

    private static func awkSplit(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        guard args.count >= 2 else { return .number(0) }
        let source = try AwkExpressions.eval(ctx, args[0]).asString
        guard case .variable(let arrayName) = args[1] else { return .number(0) }

        var fieldSep: String = ctx.FS
        var fsIsRegex = false
        if args.count >= 3 {
            if case .regex(let pattern) = args[2] {
                fieldSep = pattern
                fsIsRegex = true
            } else {
                fieldSep = try AwkExpressions.eval(ctx, args[2]).asString
            }
        }
        let parts = splitForAwk(source: source,
                                fieldSep: fieldSep,
                                isRegex: fsIsRegex)
        let arr = AwkArray()
        for (idx, part) in parts.enumerated() {
            arr[String(idx + 1)] = .string(part)
        }
        let resolved = AwkExpressions.resolveArray(ctx, arrayName)
        ctx.arrays[resolved] = arr
        return .number(Double(parts.count))
    }

    private static func splitForAwk(source: String,
                                    fieldSep: String,
                                    isRegex: Bool) -> [String] {
        if fieldSep == " " {
            return source.split(omittingEmptySubsequences: true,
                                whereSeparator: { $0.isWhitespace })
                .map { String($0) }
        }
        if isRegex || fieldSep.count > 1 {
            if let regex = try? NSRegularExpression(pattern: fieldSep) {
                let nsstr = source as NSString
                var collected: [String] = []
                var lastEnd = 0
                regex.enumerateMatches(
                    in: source,
                    range: NSRange(location: 0, length: nsstr.length)
                ) { match, _, _ in
                    guard let match else { return }
                    collected.append(nsstr.substring(with: NSRange(
                        location: lastEnd,
                        length: match.range.location - lastEnd)))
                    lastEnd = match.range.location + match.range.length
                }
                collected.append(nsstr.substring(from: lastEnd))
                return collected
            }
            return source.components(separatedBy: fieldSep)
        }
        return source.components(separatedBy: fieldSep)
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
        for match in matches {
            count += 1
            if match.range.location > pos {
                result += nsstr.substring(with: NSRange(location: pos, length: match.range.location - pos))
            }
            if !global && count > 1 {
                result += nsstr.substring(with: match.range)
            } else {
                result += expandSubReplacement(replacement, match: match, in: nsstr)
            }
            pos = match.range.location + match.range.length
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
        for match in matches {
            count += 1
            if match.range.location > pos {
                result += nsstr.substring(with: NSRange(location: pos, length: match.range.location - pos))
            }
            let shouldReplace = isGlobal || count == nth
            if shouldReplace {
                result += expandGensubReplacement(replacement, match: match, in: nsstr)
            } else {
                result += nsstr.substring(with: match.range)
            }
            pos = match.range.location + match.range.length
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
        let source = try AwkExpressions.eval(ctx, args[0]).asString
        let pattern = try patternArg(ctx, args[1])
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            ctx.RSTART = 0
            ctx.RLENGTH = -1
            return .number(0)
        }
        let nsstr = source as NSString
        if let match = regex.firstMatch(
            in: source,
            range: NSRange(location: 0, length: nsstr.length)) {
            ctx.RSTART = match.range.location + 1
            ctx.RLENGTH = match.range.length
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
        for idx in 1..<args.count {
            values.append(try AwkExpressions.eval(ctx, args[idx]))
        }
        return .string(AwkPrintf.format(fmt, values: values))
    }

    // MARK: - Time builtins

    private static func awkMktime(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        guard !args.isEmpty else { return .number(-1) }
        let source = try AwkExpressions.eval(ctx, args[0]).asString
        let parts = source.split(separator: " ").compactMap { Int($0) }
        guard parts.count >= 6 else { return .number(-1) }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = parts[3]
        components.minute = parts[4]
        components.second = parts[5]
        components.timeZone = TimeZone(identifier: "UTC")
        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            return .number(-1)
        }
        return .number(date.timeIntervalSince1970)
    }

    private static func awkStrftime(_ ctx: AwkContext, _ args: [AwkExpr]) throws -> AwkValue {
        let fmt = args.isEmpty ? "%a %b %e %H:%M:%S %Z %Y" :
            try AwkExpressions.eval(ctx, args[0]).asString
        let epoch = args.count > 1 ?
            try AwkExpressions.eval(ctx, args[1]).asNumber :
            Date().timeIntervalSince1970
        let date = Date(timeIntervalSince1970: epoch)
        return .string(formatDate(date, fmt))
    }

    // Format `date` using a subset of strftime specifiers. The
    // long/short day and month names come from `DateFormatter`; the
    // numeric fields read from `DateComponents` directly.
    private static func formatDate(_ date: Date, _ fmt: String) -> String {
        let cal = Calendar(identifier: .gregorian)
        let utcZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let components = cal.dateComponents(in: utcZone, from: date)
        let labels = dateLabels(for: date)
        var out = ""
        var cursor = fmt.startIndex
        while cursor < fmt.endIndex {
            let char = fmt[cursor]
            if char == "%" {
                cursor = fmt.index(after: cursor)
                if cursor >= fmt.endIndex { break }
                out += formatSpecifier(
                    fmt[cursor], components: components, labels: labels)
                cursor = fmt.index(after: cursor)
            } else {
                out.append(char)
                cursor = fmt.index(after: cursor)
            }
        }
        return out
    }

    private struct DateLabels {
        let dayLong: String
        let dayShort: String
        let monthLong: String
        let monthShort: String
    }

    private static func dateLabels(for date: Date) -> DateLabels {
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
        return DateLabels(
            dayLong: dayLong, dayShort: dayShort,
            monthLong: monthLong, monthShort: monthShort)
    }

    // 12-case strftime specifier table; one-liners read better inline.
    // swiftlint:disable:next cyclomatic_complexity
    private static func formatSpecifier(_ char: Character,
                                        components: DateComponents,
                                        labels: DateLabels) -> String {
        switch char {
        case "Y": return String(format: "%04d", components.year ?? 1970)
        case "m": return String(format: "%02d", components.month ?? 1)
        case "d": return String(format: "%02d", components.day ?? 1)
        case "H": return String(format: "%02d", components.hour ?? 0)
        case "M": return String(format: "%02d", components.minute ?? 0)
        case "S": return String(format: "%02d", components.second ?? 0)
        case "A": return labels.dayLong
        case "a": return labels.dayShort
        case "B": return labels.monthLong
        case "b", "h": return labels.monthShort
        case "Z": return "UTC"
        case "%": return "%"
        case "e": return String(format: "%2d", components.day ?? 1)
        default: return String(char)
        }
    }

    // MARK: - Substitute helpers

    private static func patternArg(_ ctx: AwkContext, _ arg: AwkExpr) throws -> String {
        if case .regex(let pattern) = arg { return pattern }
        var pattern = try AwkExpressions.eval(ctx, arg).asString
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count >= 2 {
            pattern = String(pattern.dropFirst().dropLast())
        }
        return pattern
    }

    /// Returns (read-current, write-new) for sub/gsub's optional 3rd
    /// argument: variable, field, or default to $0.
    private static func targetIO(_ ctx: AwkContext, _ arg: AwkExpr?) -> (() -> String, (String) throws -> Void) {
        guard let arg else {
            return ({ ctx.line }, { value in AwkFields.setLine(ctx, value) })
        }
        switch arg {
        case .variable(let name):
            return (
                { (AwkExpressions.getVariable(ctx, name)).asString },
                { value in AwkExpressions.setVariable(ctx, name, .string(value)) }
            )
        case .field(let idxExpr):
            let getIdx: () throws -> Int = {
                Int(try AwkExpressions.eval(ctx, idxExpr).asNumber.rounded(.towardZero))
            }
            return (
                { (try? AwkFields.getField(ctx, getIdx()).asString) ?? "" },
                { value in AwkFields.setField(ctx, try getIdx(), .string(value)) }
            )
        case .arrayAccess(let name, let key):
            return (
                { (try? AwkExpressions.getArrayElement(
                    ctx, name, AwkExpressions.eval(ctx, key).asString).asString) ?? "" },
                { value in
                    let resolvedKey = try AwkExpressions.eval(ctx, key).asString
                    AwkExpressions.setArrayElement(ctx, name, resolvedKey, .string(value))
                }
            )
        default:
            return ({ ctx.line }, { value in AwkFields.setLine(ctx, value) })
        }
    }

    private static func expandSubReplacement(_ rep: String,
                                             match: NSTextCheckingResult,
                                             in nsstr: NSString) -> String {
        var out = ""
        let chars = Array(rep)
        var idx = 0
        while idx < chars.count {
            let char = chars[idx]
            if char == "\\" && idx + 1 < chars.count {
                let next = chars[idx + 1]
                if next == "&" { out += "&"; idx += 2; continue }
                if next == "\\" { out += "\\"; idx += 2; continue }
                out.append(next); idx += 2; continue
            }
            if char == "&" {
                out += nsstr.substring(with: match.range)
                idx += 1
                continue
            }
            out.append(char)
            idx += 1
        }
        return out
    }

    private static func expandGensubReplacement(_ rep: String,
                                                match: NSTextCheckingResult,
                                                in nsstr: NSString) -> String {
        var out = ""
        let chars = Array(rep)
        var idx = 0
        while idx < chars.count {
            let char = chars[idx]
            if char == "\\" && idx + 1 < chars.count {
                let next = chars[idx + 1]
                if next == "&" { out += "&"; idx += 2; continue }
                if next == "0" {
                    out += nsstr.substring(with: match.range)
                    idx += 2
                    continue
                }
                if let digit = next.asciiValue, digit >= 0x31, digit <= 0x39 {
                    let groupIdx = Int(digit - 0x30)
                    if groupIdx < match.numberOfRanges {
                        let range = match.range(at: groupIdx)
                        if range.location != NSNotFound {
                            out += nsstr.substring(with: range)
                        }
                    }
                    idx += 2
                    continue
                }
                if next == "n" { out += "\n"; idx += 2; continue }
                if next == "t" { out += "\t"; idx += 2; continue }
                out.append(next); idx += 2; continue
            }
            if char == "&" {
                out += nsstr.substring(with: match.range)
                idx += 1
                continue
            }
            out.append(char)
            idx += 1
        }
        return out
    }

    // MARK: - Random

    private static func awkRand(_ ctx: AwkContext) -> Double {
        // Linear-congruential generator — gives deterministic
        // sequences for srand(42); enough for AWK's typical usage.
        var state = ctx.randomState
        state = state &* 6364136223846793005 &+ 1442695040888963407
        ctx.randomState = state
        // Return [0,1).
        return Double((state >> 11) & 0x1FFFFFFFFFFFFF) / Double(1 << 53)
    }
}
