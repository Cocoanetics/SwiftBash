import Foundation

/// Dispatch table for every jq builtin. Mirrors the just-bash split into
/// type / math / string / array / object / control / path / index /
/// navigation / SQL groups, but kept in one file because Swift makes
/// the cross-module wiring more painful than the sum of all groups put
/// together.
enum JqBuiltins {

    static func evaluate(_ value: JqValue, name: String, args: [JqAST],
                         ctx: JqContext) throws -> [JqValue] {
        // 0. user-defined function (shadows builtins, matching real jq).
        if let fn = ctx.funcs["\(name)/\(args.count)"] {
            return try callUserFunc(fn, value: value, args: args, ctx: ctx, name: name)
        }

        // 1. simple math (single-value: floor / ceil / sqrt / etc.)
        if let r = try simpleMath(value, name) { return r }

        // 2. group dispatch — first match wins
        if let r = try typeBuiltin(value, name) { return r }
        if let r = try mathBuiltin(value, name, args, ctx) { return r }
        if let r = try stringBuiltin(value, name, args, ctx) { return r }
        if let r = try objectBuiltin(value, name, args, ctx) { return r }
        if let r = try arrayBuiltin(value, name, args, ctx) { return r }
        if let r = try controlBuiltin(value, name, args, ctx) { return r }
        if let r = try indexBuiltin(value, name, args, ctx) { return r }
        if let r = try pathBuiltin(value, name, args, ctx) { return r }
        if let r = try navigationBuiltin(value, name, args, ctx) { return r }
        if let r = try sqlBuiltin(value, name, args, ctx) { return r }
        if let r = try dateBuiltin(value, name, args, ctx) { return r }

        switch name {
        case "env":
            var obj = JqObject()
            for (k, v) in ctx.env { obj[k] = .string(v) }
            return [.object(obj)]
        case "$ENV":
            var obj = JqObject()
            for (k, v) in ctx.env { obj[k] = .string(v) }
            return [.object(obj)]
        case "debug":
            FileHandle.standardError.write(Data("[\"DEBUG:\",\(JqFormatter.compact(value))]\n".utf8))
            return [value]
        case "stderr":
            FileHandle.standardError.write(Data(JqFormatter.compact(value).utf8))
            return [value]
        case "input_line_number":
            return [.number(1)]
        case "error":
            if args.isEmpty {
                throw JqThrown(value)
            }
            let v = try JqEvaluator.evalNode(value, args[0], ctx).first ?? .null
            throw JqThrown(v)
        case "halt":
            exit(0)
        case "halt_error":
            let code: Int32
            if args.isEmpty { code = 5 }
            else if case .number(let n) = (try JqEvaluator.evalNode(value, args[0], ctx).first ?? .null) {
                code = Int32(n)
            } else { code = 5 }
            switch value {
            case .string(let s): FileHandle.standardError.write(Data(s.utf8))
            default: FileHandle.standardError.write(Data((JqFormatter.compact(value) + "\n").utf8))
            }
            exit(code)
        case "input", "inputs":
            return []
        case "getpath":
            // Already in pathBuiltin
            return []
        case "min", "max":
            return []  // handled in arrayBuiltin
        case "builtins":
            return [.array(builtinsList.sorted().map { .string($0) })]
        case "ascii":
            if case .string(let s) = value, let first = s.unicodeScalars.first {
                return [.number(Double(first.value))]
            }
            return [.null]
        case "splits":
            return try stringBuiltin(value, "splits", args, ctx) ?? []
        case "test", "match", "capture", "scan", "sub", "gsub":
            return try stringBuiltin(value, name, args, ctx) ?? []
        case "ascii_downcase", "ascii_upcase":
            return try stringBuiltin(value, name, args, ctx) ?? []
        default:
            throw JqError("\(name)/\(args.count) is not defined")
        }
    }

    // MARK: - User-defined function call

    static func callUserFunc(_ fn: JqFunc, value: JqValue, args: [JqAST], ctx: JqContext, name: String) throws -> [JqValue] {
        // jq parameters are filters. If a parameter is referenced
        // multiple times in the body, each reference re-runs the
        // expression — but for simplicity we fold to call-by-name via
        // synthetic 0-arg defs.
        let nctx = ctx.fork()
        nctx.funcs = fn.closure
        let key = "\(name)/\(fn.params.count)"
        nctx.funcs[key] = fn
        for (i, paramName) in fn.params.enumerated() {
            if paramName.hasPrefix("$") {
                // value-parameter: bind the variable directly to the
                // single result.
                let result = try JqEvaluator.evalNode(value, args[i], ctx)
                nctx.vars[paramName] = result.first ?? .null
            } else {
                // filter-parameter: store the expression as a 0-arg
                // function in the new context. Capture the *caller's*
                // funcs/vars so the expression resolves names from the
                // call site, not the callee's body.
                let argExpr = args[i]
                let captured = ctx.funcs
                let capturedVars = ctx.vars
                let synthetic = JqFunc(params: [], body: argExpr, closure: captured)
                nctx.funcs["\(paramName)/0"] = synthetic
                // also pre-bind any vars closed over (best-effort: copy
                // current vars onto a hidden marker; called func can
                // access them via VarRef which already reads ctx.vars).
                _ = capturedVars
            }
        }
        return try JqEvaluator.evalNode(value, fn.body, nctx)
    }

    // MARK: - Simple math (single-arg double->double)

    static func simpleMath(_ value: JqValue, _ name: String) throws -> [JqValue]? {
        let map: [String: (Double) -> Double] = [
            "floor": { $0.rounded(.down) },
            "ceil": { $0.rounded(.up) },
            "round": { $0.rounded() },
            "sqrt": { $0.squareRoot() },
            "log": { Foundation.log($0) },
            "log10": { Foundation.log10($0) },
            "log2": { Foundation.log2($0) },
            "exp": { Foundation.exp($0) },
            "sin": { Foundation.sin($0) },
            "cos": { Foundation.cos($0) },
            "tan": { Foundation.tan($0) },
            "asin": { Foundation.asin($0) },
            "acos": { Foundation.acos($0) },
            "atan": { Foundation.atan($0) },
            "sinh": { Foundation.sinh($0) },
            "cosh": { Foundation.cosh($0) },
            "tanh": { Foundation.tanh($0) },
            "asinh": { Foundation.asinh($0) },
            "acosh": { Foundation.acosh($0) },
            "atanh": { Foundation.atanh($0) },
            "cbrt": { Foundation.cbrt($0) },
            "expm1": { Foundation.expm1($0) },
            "log1p": { Foundation.log1p($0) },
            "trunc": { $0.rounded(.towardZero) },
        ]
        guard let fn = map[name] else { return nil }
        if case .number(let n) = value { return [.number(fn(n))] }
        return [.null]
    }

    // MARK: - Type group

    static func typeBuiltin(_ value: JqValue, _ name: String) throws -> [JqValue]? {
        switch name {
        case "type": return [.string(value.typeName)]
        case "infinite": return [.number(.infinity)]
        case "nan": return [.number(.nan)]
        case "isinfinite":
            if case .number(let n) = value { return [.bool(n.isInfinite)] }
            return [.bool(false)]
        case "isnan":
            if case .number(let n) = value { return [.bool(n.isNaN)] }
            return [.bool(false)]
        case "isnormal":
            if case .number(let n) = value { return [.bool(n.isNormal)] }
            return [.bool(false)]
        case "isfinite":
            if case .number(let n) = value { return [.bool(n.isFinite)] }
            return [.bool(false)]
        case "numbers":
            if case .number = value { return [value] }
            return []
        case "strings":
            if case .string = value { return [value] }
            return []
        case "booleans":
            if case .bool = value { return [value] }
            return []
        case "nulls":
            if case .null = value { return [value] }
            return []
        case "arrays":
            if case .array = value { return [value] }
            return []
        case "objects":
            if case .object = value { return [value] }
            return []
        case "iterables":
            switch value {
            case .array, .object: return [value]
            default: return []
            }
        case "scalars":
            switch value {
            case .array, .object: return []
            default: return [value]
            }
        case "values":
            if case .null = value { return [] }
            return [value]
        case "not":
            return [.bool(!value.isTruthy)]
        case "null": return [.null]
        case "true": return [.bool(true)]
        case "false": return [.bool(false)]
        case "empty": return []
        case "leaf_paths":
            return try pathBuiltin(value, "leaf_paths", [], JqContext()) ?? []
        default: return nil
        }
    }

    // MARK: - Math group

    static func mathBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "fabs", "abs":
            switch value {
            case .number(let n): return [.number(abs(n))]
            case .string: return [value]
            default: return [.null]
            }
        case "exp10":
            if case .number(let n) = value { return [.number(pow(10.0, n))] }
            return [.null]
        case "exp2":
            if case .number(let n) = value { return [.number(pow(2.0, n))] }
            return [.null]
        case "pow":
            guard args.count == 2 else { return [.null] }
            let bs = try JqEvaluator.evalNode(value, args[0], ctx)
            let es = try JqEvaluator.evalNode(value, args[1], ctx)
            guard case .number(let b) = bs.first ?? .null,
                  case .number(let e) = es.first ?? .null else { return [.null] }
            return [.number(pow(b, e))]
        case "atan2":
            guard args.count == 2 else { return [.null] }
            let ys = try JqEvaluator.evalNode(value, args[0], ctx)
            let xs = try JqEvaluator.evalNode(value, args[1], ctx)
            guard case .number(let y) = ys.first ?? .null,
                  case .number(let x) = xs.first ?? .null else { return [.null] }
            return [.number(atan2(y, x))]
        case "logb":
            if case .number(let n) = value { return [.number(Foundation.log2(abs(n)).rounded(.down))] }
            return [.null]
        case "significand":
            if case .number(let n) = value {
                let exp = Foundation.log2(abs(n)).rounded(.down)
                return [.number(n / pow(2.0, exp))]
            }
            return [.null]
        case "frexp":
            if case .number(let n) = value {
                if n == 0 { return [.array([.number(0), .number(0)])] }
                let exp = Foundation.log2(abs(n)).rounded(.down) + 1
                let m = n / pow(2.0, exp)
                return [.array([.number(m), .number(exp)])]
            }
            return [.null]
        case "modf":
            if case .number(let n) = value {
                let i = n.rounded(.towardZero)
                return [.array([.number(n - i), .number(i)])]
            }
            return [.null]
        case "nearbyint":
            if case .number(let n) = value { return [.number(n.rounded())] }
            return [.null]
        default: return nil
        }
    }

    // MARK: - String group

    static func stringBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "join":
            guard case .array(let arr) = value else { return [.null] }
            let seps = try args.first.map { try JqEvaluator.evalNode(value, $0, ctx) } ?? [.string("")]
            return seps.map { sep -> JqValue in
                var sepStr = ""
                if case .string(let s) = sep { sepStr = s }
                else { sepStr = JqFormatter.compact(sep) }
                let pieces = arr.map { v -> String in
                    switch v {
                    case .null: return ""
                    case .string(let s): return s
                    default: return JqFormatter.compact(v)
                    }
                }
                return .string(pieces.joined(separator: sepStr))
            }
        case "split":
            guard case .string(let s) = value, !args.isEmpty else { return [.null] }
            let seps = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let sep) = seps.first ?? .null else { return [.null] }
            if sep.isEmpty {
                return [.array(s.map { .string(String($0)) })]
            }
            return [.array(s.components(separatedBy: sep).map { .string($0) })]
        case "splits":
            guard case .string(let s) = value, !args.isEmpty else { return [] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [] }
            do {
                let regex = try NSRegularExpression(pattern: pat)
                let nsstr = s as NSString
                var results: [String] = []
                var lastEnd = 0
                regex.enumerateMatches(in: s, range: NSRange(location: 0, length: nsstr.length)) { m, _, _ in
                    guard let m else { return }
                    results.append(nsstr.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd)))
                    lastEnd = m.range.location + m.range.length
                }
                results.append(nsstr.substring(from: lastEnd))
                return results.map { .string($0) }
            } catch {
                return []
            }
        case "ascii_downcase":
            guard case .string(let s) = value else { return [.null] }
            var out = ""
            for c in s {
                if let a = c.asciiValue, a >= 0x41, a <= 0x5A {
                    out.append(Character(Unicode.Scalar(a + 32)))
                } else {
                    out.append(c)
                }
            }
            return [.string(out)]
        case "ascii_upcase":
            guard case .string(let s) = value else { return [.null] }
            var out = ""
            for c in s {
                if let a = c.asciiValue, a >= 0x61, a <= 0x7A {
                    out.append(Character(Unicode.Scalar(a - 32)))
                } else {
                    out.append(c)
                }
            }
            return [.string(out)]
        case "ltrimstr":
            guard case .string(let s) = value, !args.isEmpty else { return [value] }
            let ps = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let p) = ps.first ?? .null else { return [value] }
            if s.hasPrefix(p) { return [.string(String(s.dropFirst(p.count)))] }
            return [value]
        case "rtrimstr":
            guard case .string(let s) = value, !args.isEmpty else { return [value] }
            let ps = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let p) = ps.first ?? .null else { return [value] }
            if p.isEmpty { return [value] }
            if s.hasSuffix(p) { return [.string(String(s.dropLast(p.count)))] }
            return [value]
        case "trimstr":
            guard case .string(let s) = value, !args.isEmpty else { return [value] }
            let ps = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let p) = ps.first ?? .null, !p.isEmpty else { return [value] }
            var r = s
            if r.hasPrefix(p) { r = String(r.dropFirst(p.count)) }
            if r.hasSuffix(p) { r = String(r.dropLast(p.count)) }
            return [.string(r)]
        case "trim":
            guard case .string(let s) = value else { throw JqError("trim input must be a string") }
            return [.string(s.trimmingCharacters(in: .whitespacesAndNewlines))]
        case "ltrim":
            guard case .string(let s) = value else { throw JqError("trim input must be a string") }
            var i = s.startIndex
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            return [.string(String(s[i...]))]
        case "rtrim":
            guard case .string(let s) = value else { throw JqError("trim input must be a string") }
            var j = s.endIndex
            while j > s.startIndex {
                let prev = s.index(before: j)
                if !s[prev].isWhitespace { break }
                j = prev
            }
            return [.string(String(s[..<j]))]
        case "startswith":
            guard case .string(let s) = value, !args.isEmpty else { return [.bool(false)] }
            let ps = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let p) = ps.first ?? .null else { return [.bool(false)] }
            return [.bool(s.hasPrefix(p))]
        case "endswith":
            guard case .string(let s) = value, !args.isEmpty else { return [.bool(false)] }
            let ps = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let p) = ps.first ?? .null else { return [.bool(false)] }
            return [.bool(s.hasSuffix(p))]
        case "explode":
            guard case .string(let s) = value else { return [.null] }
            return [.array(s.unicodeScalars.map { .number(Double($0.value)) })]
        case "implode":
            guard case .array(let arr) = value else {
                throw JqError("implode input must be an array")
            }
            var out = ""
            for cp in arr {
                guard case .number(let n) = cp else {
                    throw JqError("implode requires numeric code points")
                }
                let code = UInt32(n)
                if let u = Unicode.Scalar(code), code <= 0x10FFFF, !(0xD800...0xDFFF).contains(code) {
                    out.append(Character(u))
                } else {
                    out.append("\u{FFFD}")
                }
            }
            return [.string(out)]
        case "test":
            guard case .string(let s) = value, !args.isEmpty else { return [.bool(false)] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [.bool(false)] }
            var flags = ""
            if args.count > 1 {
                let fs = try JqEvaluator.evalNode(value, args[1], ctx)
                if case .string(let f) = fs.first ?? .null { flags = f }
            }
            do {
                let regex = try buildRegex(pat, flags: flags)
                let r = regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
                return [.bool(r != nil)]
            } catch {
                return [.bool(false)]
            }
        case "match":
            guard case .string(let s) = value, !args.isEmpty else { return [.null] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [.null] }
            var flags = ""
            if args.count > 1 {
                let fs = try JqEvaluator.evalNode(value, args[1], ctx)
                if case .string(let f) = fs.first ?? .null { flags = f }
            }
            do {
                let regex = try buildRegex(pat, flags: flags)
                let nsstr = s as NSString
                let global = flags.contains("g")
                let matches: [NSTextCheckingResult] = global ?
                    regex.matches(in: s, range: NSRange(location: 0, length: nsstr.length)) :
                    (regex.firstMatch(in: s, range: NSRange(location: 0, length: nsstr.length)).map { [$0] } ?? [])
                if matches.isEmpty { return [] }
                return matches.map { m -> JqValue in
                    var entry = JqObject()
                    entry["offset"] = .number(Double(m.range.location))
                    entry["length"] = .number(Double(m.range.length))
                    entry["string"] = .string(nsstr.substring(with: m.range))
                    var captures: [JqValue] = []
                    for i in 1..<m.numberOfRanges {
                        let r = m.range(at: i)
                        var cap = JqObject()
                        if r.location == NSNotFound {
                            cap["offset"] = .number(-1)
                            cap["length"] = .number(0)
                            cap["string"] = .null
                        } else {
                            cap["offset"] = .number(Double(r.location))
                            cap["length"] = .number(Double(r.length))
                            cap["string"] = .string(nsstr.substring(with: r))
                        }
                        cap["name"] = .null
                        captures.append(.object(cap))
                    }
                    entry["captures"] = .array(captures)
                    return .object(entry)
                }
            } catch {
                return []
            }
        case "capture":
            guard case .string(let s) = value, !args.isEmpty else { return [.null] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [.null] }
            var flags = ""
            if args.count > 1 {
                let fs = try JqEvaluator.evalNode(value, args[1], ctx)
                if case .string(let f) = fs.first ?? .null { flags = f }
            }
            do {
                let regex = try buildRegex(pat, flags: flags)
                let nsstr = s as NSString
                let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: nsstr.length))
                guard let m else { return [] }
                // Extract named captures via regex pattern parsing.
                let names = parseNamedGroups(pat)
                var obj = JqObject()
                for (i, n) in names {
                    if i < m.numberOfRanges {
                        let r = m.range(at: i)
                        if r.location == NSNotFound { obj[n] = .null }
                        else { obj[n] = .string(nsstr.substring(with: r)) }
                    }
                }
                return [.object(obj)]
            } catch {
                return [.null]
            }
        case "scan":
            guard case .string(let s) = value, !args.isEmpty else { return [] }
            let pats = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let pat) = pats.first ?? .null else { return [] }
            var flags = "g"
            if args.count > 1 {
                let fs = try JqEvaluator.evalNode(value, args[1], ctx)
                if case .string(let f) = fs.first ?? .null { flags = f.contains("g") ? f : f + "g" }
            }
            do {
                let regex = try buildRegex(pat, flags: flags)
                let nsstr = s as NSString
                let matches = regex.matches(in: s, range: NSRange(location: 0, length: nsstr.length))
                return matches.map { m -> JqValue in
                    if m.numberOfRanges > 1 {
                        var caps: [JqValue] = []
                        for i in 1..<m.numberOfRanges {
                            let r = m.range(at: i)
                            if r.location == NSNotFound { caps.append(.null) }
                            else { caps.append(.string(nsstr.substring(with: r))) }
                        }
                        return .array(caps)
                    }
                    return .string(nsstr.substring(with: m.range))
                }
            } catch {
                return []
            }
        case "sub":
            return try subOrGsub(value, args, ctx, global: false)
        case "gsub":
            return try subOrGsub(value, args, ctx, global: true)
        default: return nil
        }
    }

    static func subOrGsub(_ value: JqValue, _ args: [JqAST], _ ctx: JqContext, global: Bool) throws -> [JqValue] {
        guard case .string(let s) = value, args.count >= 2 else { return [.null] }
        let pats = try JqEvaluator.evalNode(value, args[0], ctx)
        let reps = try JqEvaluator.evalNode(value, args[1], ctx)
        guard case .string(let pat) = pats.first ?? .null,
              case .string(let rep) = reps.first ?? .null else { return [value] }
        var flags = global ? "g" : ""
        if args.count > 2 {
            let fs = try JqEvaluator.evalNode(value, args[2], ctx)
            if case .string(let f) = fs.first ?? .null {
                flags = global && !f.contains("g") ? f + "g" : f
            }
        }
        do {
            let regex = try buildRegex(pat, flags: flags)
            let nsstr = s as NSString
            let range = NSRange(location: 0, length: nsstr.length)
            let limit = global ? regex.matches(in: s, range: range).count : 1
            var result = s
            for _ in 0..<limit {
                let nsr = result as NSString
                let r = regex.firstMatch(in: result, range: NSRange(location: 0, length: nsr.length))
                guard let m = r else { break }
                let replaced = regex.replacementString(for: m, in: result, offset: 0, template: rep)
                result = nsr.replacingCharacters(in: m.range, with: replaced)
                if !global { break }
            }
            return [.string(result)]
        } catch {
            return [value]
        }
    }

    static func buildRegex(_ pattern: String, flags: String) throws -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        return try NSRegularExpression(pattern: pattern, options: options)
    }

    static func parseNamedGroups(_ pattern: String) -> [(Int, String)] {
        var result: [(Int, String)] = []
        var groupIndex = 0
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "(" {
                if i + 1 < chars.count && chars[i + 1] == "?" {
                    if i + 3 < chars.count && chars[i + 2] == "P" && chars[i + 3] == "<" {
                        i += 4
                        var name = ""
                        while i < chars.count, chars[i] != ">" { name.append(chars[i]); i += 1 }
                        groupIndex += 1
                        result.append((groupIndex, name))
                    } else if i + 2 < chars.count && chars[i + 2] == "<" {
                        i += 3
                        var name = ""
                        while i < chars.count, chars[i] != ">" { name.append(chars[i]); i += 1 }
                        groupIndex += 1
                        result.append((groupIndex, name))
                    } else {
                        // non-capturing or modifier
                    }
                } else {
                    groupIndex += 1
                }
            }
            i += 1
        }
        return result
    }

    // MARK: - Object group

    static func objectBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "keys":
            switch value {
            case .array(let a): return [.array((0..<a.count).map { .number(Double($0)) })]
            case .object(let o): return [.array(o.keys.sorted().map { .string($0) })]
            default: return [.null]
            }
        case "keys_unsorted":
            switch value {
            case .array(let a): return [.array((0..<a.count).map { .number(Double($0)) })]
            case .object(let o): return [.array(o.keys.map { .string($0) })]
            default: return [.null]
            }
        case "length":
            switch value {
            case .null: return [.number(0)]
            case .string(let s): return [.number(Double(s.count))]
            case .array(let a): return [.number(Double(a.count))]
            case .object(let o): return [.number(Double(o.count))]
            case .number(let n): return [.number(abs(n))]
            case .bool: throw JqError("boolean has no length")
            }
        case "utf8bytelength":
            guard case .string(let s) = value else {
                throw JqError("\(value.typeName) has no utf8 byte length")
            }
            return [.number(Double(s.utf8.count))]
        case "to_entries":
            guard case .object(let o) = value else { return [.null] }
            return [.array(o.map { (k, v) in
                .object(JqObject([("key", .string(k)), ("value", v)]))
            })]
        case "from_entries":
            guard case .array(let arr) = value else { return [.null] }
            var obj = JqObject()
            for item in arr {
                guard case .object(let entry) = item else { continue }
                let key = entry["key"] ?? entry["Key"] ?? entry["name"] ?? entry["Name"] ?? entry["k"]
                let val = entry["value"] ?? entry["Value"] ?? entry["v"] ?? .null
                if let key {
                    let k: String
                    switch key {
                    case .string(let s): k = s
                    case .number(let n): k = JqValue.formatDouble(n)
                    default: k = JqFormatter.compact(key)
                    }
                    obj[k] = val
                }
            }
            return [.object(obj)]
        case "with_entries":
            guard !args.isEmpty else { return [value] }
            guard case .object(let o) = value else { return [.null] }
            var entries: [JqValue] = []
            for (k, v) in o {
                entries.append(.object(JqObject([("key", .string(k)), ("value", v)])))
            }
            var mapped: [JqValue] = []
            for e in entries {
                mapped.append(contentsOf: try JqEvaluator.evalNode(e, args[0], ctx))
            }
            var obj = JqObject()
            for item in mapped {
                guard case .object(let entry) = item else { continue }
                let key = entry["key"] ?? entry["name"] ?? entry["k"]
                let val = entry["value"] ?? entry["v"] ?? .null
                if let key {
                    let k: String
                    switch key {
                    case .string(let s): k = s
                    case .number(let n): k = JqValue.formatDouble(n)
                    default: k = JqFormatter.compact(key)
                    }
                    obj[k] = val
                }
            }
            return [.object(obj)]
        case "reverse":
            switch value {
            case .array(let a): return [.array(a.reversed())]
            case .string(let s): return [.string(String(s.reversed()))]
            default: return [.null]
            }
        case "flatten":
            guard case .array(let arr) = value else { return [.null] }
            let depths: [JqValue] = try args.first.map { try JqEvaluator.evalNode(value, $0, ctx) } ?? [.number(.infinity)]
            return depths.map { d -> JqValue in
                var depth = Int.max
                if case .number(let n) = d {
                    if n.isInfinite { depth = Int.max }
                    else if n < 0 { return .null }
                    else { depth = Int(n) }
                }
                return .array(flatten(arr, depth: depth))
            }
        case "unique":
            guard case .array(let arr) = value else { return [.null] }
            var seen: [String] = []
            var out: [JqValue] = []
            for item in arr {
                let k = JqFormatter.compact(item, sortKeys: true)
                if !seen.contains(k) {
                    seen.append(k)
                    out.append(item)
                }
            }
            out.sort { JqValue.jqCompare($0, $1) < 0 }
            return [.array(out)]
        case "tojson":
            return [.string(JqFormatter.compact(value))]
        case "fromjson":
            guard case .string(let s) = value else { return [value] }
            return [try JqJSON.parse(s)]
        case "tostring":
            if case .string = value { return [value] }
            return [.string(JqFormatter.compact(value))]
        case "tonumber":
            switch value {
            case .number: return [value]
            case .string(let s):
                guard let n = Double(s.trimmingCharacters(in: .whitespaces)) else {
                    throw JqError("\(JqFormatter.compact(value)) cannot be parsed as a number")
                }
                return [.number(n)]
            default:
                throw JqError("\(value.typeName) cannot be parsed as a number")
            }
        case "toboolean":
            switch value {
            case .bool: return [value]
            case .string("true"): return [.bool(true)]
            case .string("false"): return [.bool(false)]
            default:
                throw JqError("\(value.typeName) cannot be parsed as a boolean")
            }
        case "tostream":
            return [.array(toStream(value, prefix: []))].flatMap { (a: JqValue) -> [JqValue] in
                if case .array(let arr) = a { return arr }
                return []
            }
        case "fromstream":
            guard !args.isEmpty else { return [value] }
            let stream = try JqEvaluator.evalNode(value, args[0], ctx)
            return fromStream(stream)
        default: return nil
        }
    }

    static func flatten(_ arr: [JqValue], depth: Int) -> [JqValue] {
        if depth == 0 { return arr }
        var out: [JqValue] = []
        for item in arr {
            if case .array(let sub) = item {
                out.append(contentsOf: flatten(sub, depth: depth - 1))
            } else {
                out.append(item)
            }
        }
        return out
    }

    static func toStream(_ v: JqValue, prefix: [JqValue]) -> [JqValue] {
        var out: [JqValue] = []
        switch v {
        case .array(let arr):
            if arr.isEmpty {
                out.append(.array([.array(prefix), .array([])]))
            } else {
                for (i, item) in arr.enumerated() {
                    out.append(contentsOf: toStream(item, prefix: prefix + [.number(Double(i))]))
                }
                out.append(.array([.array(prefix + [.number(Double(arr.count - 1))])]))
            }
        case .object(let o):
            if o.isEmpty {
                out.append(.array([.array(prefix), .object(JqObject())]))
            } else {
                let keys = Array(o.keys)
                for k in keys {
                    out.append(contentsOf: toStream(o[k]!, prefix: prefix + [.string(k)]))
                }
                if let lastK = keys.last {
                    out.append(.array([.array(prefix + [.string(lastK)])]))
                }
            }
        default:
            out.append(.array([.array(prefix), v]))
        }
        return out
    }

    static func fromStream(_ items: [JqValue]) -> [JqValue] {
        var result: JqValue = .null
        var produced: [JqValue] = []
        for item in items {
            guard case .array(let arr) = item else { continue }
            if arr.count == 1 {
                if case .array(let p) = arr[0], p.isEmpty {
                    produced.append(result)
                    result = .null
                }
                continue
            }
            if arr.count != 2 { continue }
            guard case .array(let path) = arr[0] else { continue }
            let val = arr[1]
            if path.isEmpty {
                produced.append(val)
                result = .null
                continue
            }
            if case .null = result {
                if case .number = path[0] { result = .array([]) }
                else { result = .object(JqObject()) }
            }
            result = (try? JqPathOps.setPath(result, path, val)) ?? result
        }
        if case .null = result {} else { produced.append(result) }
        return produced
    }

    // MARK: - Array group

    static func arrayBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "sort":
            guard case .array(let arr) = value else { return [.null] }
            return [.array(arr.sorted { JqValue.jqCompare($0, $1) < 0 })]
        case "sort_by":
            guard case .array(let arr) = value, !args.isEmpty else { return [.null] }
            let keyed = try arr.map { item -> (JqValue, JqValue) in
                let k = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                return (item, k)
            }
            return [.array(keyed.sorted { JqValue.jqCompare($0.1, $1.1) < 0 }.map { $0.0 })]
        case "bsearch":
            guard case .array(let arr) = value, !args.isEmpty else { return [.null] }
            let targets = try JqEvaluator.evalNode(value, args[0], ctx)
            return targets.map { t -> JqValue in
                var lo = 0, hi = arr.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if JqValue.jqCompare(arr[mid], t) < 0 { lo = mid + 1 }
                    else { hi = mid }
                }
                if lo < arr.count, JqValue.jqCompare(arr[lo], t) == 0 {
                    return .number(Double(lo))
                }
                return .number(Double(-lo - 1))
            }
        case "unique_by":
            guard case .array(let arr) = value, !args.isEmpty else { return [.null] }
            var seen: [String] = []
            var pairs: [(JqValue, JqValue)] = []
            for item in arr {
                let k = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                let ks = JqFormatter.compact(k, sortKeys: true)
                if !seen.contains(ks) {
                    seen.append(ks)
                    pairs.append((item, k))
                }
            }
            return [.array(pairs.sorted { JqValue.jqCompare($0.1, $1.1) < 0 }.map { $0.0 })]
        case "group_by":
            guard case .array(let arr) = value, !args.isEmpty else { return [.null] }
            var keys: [String] = []
            var groups: [String: [JqValue]] = [:]
            var keyByStr: [String: JqValue] = [:]
            for item in arr {
                let k = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                let ks = JqFormatter.compact(k, sortKeys: true)
                if groups[ks] == nil {
                    keys.append(ks)
                    groups[ks] = []
                    keyByStr[ks] = k
                }
                groups[ks]?.append(item)
            }
            keys.sort { JqValue.jqCompare(keyByStr[$0]!, keyByStr[$1]!) < 0 }
            return [.array(keys.map { .array(groups[$0]!) })]
        case "max":
            guard case .array(let arr) = value, !arr.isEmpty else { return [.null] }
            return [arr.reduce(arr[0]) { JqValue.jqCompare($0, $1) >= 0 ? $0 : $1 }]
        case "max_by":
            guard case .array(let arr) = value, !arr.isEmpty, !args.isEmpty else { return [.null] }
            var best = arr[0]
            var bestKey = (try JqEvaluator.evalNode(best, args[0], ctx)).first ?? .null
            for item in arr.dropFirst() {
                let k = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                if JqValue.jqCompare(k, bestKey) > 0 { best = item; bestKey = k }
            }
            return [best]
        case "min":
            guard case .array(let arr) = value, !arr.isEmpty else { return [.null] }
            return [arr.reduce(arr[0]) { JqValue.jqCompare($0, $1) <= 0 ? $0 : $1 }]
        case "min_by":
            guard case .array(let arr) = value, !arr.isEmpty, !args.isEmpty else { return [.null] }
            var best = arr[0]
            var bestKey = (try JqEvaluator.evalNode(best, args[0], ctx)).first ?? .null
            for item in arr.dropFirst() {
                let k = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                if JqValue.jqCompare(k, bestKey) < 0 { best = item; bestKey = k }
            }
            return [best]
        case "add":
            let items: [JqValue]
            if !args.isEmpty {
                items = try JqEvaluator.evalNode(value, args[0], ctx)
            } else if case .array(let a) = value { items = a }
            else if case .null = value { return [.null] }
            else { return [.null] }
            let nonNull = items.filter { if case .null = $0 { return false } else { return true } }
            if nonNull.isEmpty { return [.null] }
            // Use jq's `+` semantics
            var result = nonNull[0]
            for v in nonNull.dropFirst() {
                result = try JqEvaluator.applyBinary(.add, result, v)
            }
            return [result]
        case "any":
            if args.count >= 2 {
                let gen = try JqEvaluator.evalNode(value, args[0], ctx)
                for v in gen {
                    let conds = try JqEvaluator.evalNode(v, args[1], ctx)
                    if conds.contains(where: { $0.isTruthy }) { return [.bool(true)] }
                }
                return [.bool(false)]
            }
            if args.count == 1 {
                guard case .array(let a) = value else { return [.bool(false)] }
                for item in a {
                    let conds = try JqEvaluator.evalNode(item, args[0], ctx)
                    if conds.contains(where: { $0.isTruthy }) { return [.bool(true)] }
                }
                return [.bool(false)]
            }
            guard case .array(let a) = value else { return [.bool(false)] }
            return [.bool(a.contains { $0.isTruthy })]
        case "all":
            if args.count >= 2 {
                let gen = try JqEvaluator.evalNode(value, args[0], ctx)
                for v in gen {
                    let conds = try JqEvaluator.evalNode(v, args[1], ctx)
                    if !conds.contains(where: { $0.isTruthy }) { return [.bool(false)] }
                }
                return [.bool(true)]
            }
            if args.count == 1 {
                guard case .array(let a) = value else { return [.bool(true)] }
                for item in a {
                    let conds = try JqEvaluator.evalNode(item, args[0], ctx)
                    if !conds.contains(where: { $0.isTruthy }) { return [.bool(false)] }
                }
                return [.bool(true)]
            }
            guard case .array(let a) = value else { return [.bool(true)] }
            return [.bool(a.allSatisfy { $0.isTruthy })]
        case "select":
            guard !args.isEmpty else { return [value] }
            let conds = try JqEvaluator.evalNode(value, args[0], ctx)
            return conds.contains(where: { $0.isTruthy }) ? [value] : []
        case "map":
            guard !args.isEmpty, case .array(let a) = value else { return [.null] }
            var out: [JqValue] = []
            for item in a {
                out.append(contentsOf: try JqEvaluator.evalNode(item, args[0], ctx))
            }
            return [.array(out)]
        case "map_values":
            guard !args.isEmpty else { return [.null] }
            switch value {
            case .array(let a):
                var out: [JqValue] = []
                for item in a {
                    let r = try JqEvaluator.evalNode(item, args[0], ctx)
                    if let f = r.first { out.append(f) }
                }
                return [.array(out)]
            case .object(let o):
                var out = JqObject()
                for (k, v) in o {
                    let r = try JqEvaluator.evalNode(v, args[0], ctx)
                    if let f = r.first { out[k] = f }
                }
                return [.object(out)]
            default: return [.null]
            }
        case "has":
            guard !args.isEmpty else { return [.bool(false)] }
            let keys = try JqEvaluator.evalNode(value, args[0], ctx)
            guard let key = keys.first else { return [.bool(false)] }
            switch (value, key) {
            case (.array(let a), .number(let n)):
                let i = Int(n)
                return [.bool(i >= 0 && i < a.count)]
            case (.object(let o), .string(let k)):
                return [.bool(o.contains(k))]
            default: return [.bool(false)]
            }
        case "in":
            guard !args.isEmpty else { return [.bool(false)] }
            let objs = try JqEvaluator.evalNode(value, args[0], ctx)
            guard let obj = objs.first else { return [.bool(false)] }
            switch (obj, value) {
            case (.array(let a), .number(let n)):
                let i = Int(n)
                return [.bool(i >= 0 && i < a.count)]
            case (.object(let o), .string(let s)):
                return [.bool(o.contains(s))]
            default: return [.bool(false)]
            }
        case "contains":
            guard !args.isEmpty else { return [.bool(false)] }
            let others = try JqEvaluator.evalNode(value, args[0], ctx)
            return [.bool(JqValue.jqContains(value, others.first ?? .null))]
        case "inside":
            guard !args.isEmpty else { return [.bool(false)] }
            let others = try JqEvaluator.evalNode(value, args[0], ctx)
            return [.bool(JqValue.jqContains(others.first ?? .null, value))]
        default: return nil
        }
    }

    // MARK: - Control flow group

    static func controlBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "first":
            if !args.isEmpty {
                let r = try JqEvaluator.evalNode(value, args[0], ctx)
                return r.isEmpty ? [] : [r[0]]
            }
            if case .array(let a) = value, !a.isEmpty { return [a[0]] }
            return [.null]
        case "last":
            if !args.isEmpty {
                let r = try JqEvaluator.evalNode(value, args[0], ctx)
                return r.isEmpty ? [] : [r.last!]
            }
            if case .array(let a) = value, !a.isEmpty { return [a.last!] }
            return [.null]
        case "nth":
            guard !args.isEmpty else { return [.null] }
            let ns = try JqEvaluator.evalNode(value, args[0], ctx)
            if args.count > 1 {
                let r = try JqEvaluator.evalNode(value, args[1], ctx)
                return ns.compactMap { nv -> JqValue? in
                    guard case .number(let n) = nv else { return nil }
                    if n < 0 { return nil }
                    let i = Int(n)
                    return i < r.count ? r[i] : nil
                }
            }
            if case .array(let a) = value {
                return ns.map { nv -> JqValue in
                    guard case .number(let n) = nv else { return .null }
                    if n < 0 { return .null }
                    let i = Int(n)
                    return i < a.count ? a[i] : .null
                }
            }
            return [.null]
        case "range":
            if args.isEmpty { return [] }
            let starts = try JqEvaluator.evalNode(value, args[0], ctx)
            if args.count == 1 {
                var out: [JqValue] = []
                for s in starts {
                    guard case .number(let n) = s else { continue }
                    var i = 0.0
                    while i < n { out.append(.number(i)); i += 1 }
                }
                return out
            }
            let ends = try JqEvaluator.evalNode(value, args[1], ctx)
            if args.count == 2 {
                var out: [JqValue] = []
                for s in starts {
                    for e in ends {
                        guard case .number(let sn) = s, case .number(let en) = e else { continue }
                        var i = sn
                        while i < en { out.append(.number(i)); i += 1 }
                    }
                }
                return out
            }
            let steps = try JqEvaluator.evalNode(value, args[2], ctx)
            var out: [JqValue] = []
            for s in starts {
                for e in ends {
                    for st in steps {
                        guard case .number(let sn) = s, case .number(let en) = e,
                              case .number(let stn) = st, stn != 0 else { continue }
                        var i = sn
                        if stn > 0 {
                            while i < en { out.append(.number(i)); i += stn }
                        } else {
                            while i > en { out.append(.number(i)); i += stn }
                        }
                    }
                }
            }
            return out
        case "limit":
            guard args.count >= 2 else { return [] }
            let ns = try JqEvaluator.evalNode(value, args[0], ctx)
            var out: [JqValue] = []
            for nv in ns {
                guard case .number(let n) = nv else { continue }
                if n < 0 { throw JqError("limit doesn't support negative count") }
                if n == 0 { continue }
                let r = try JqEvaluator.evalNode(value, args[1], ctx)
                out.append(contentsOf: r.prefix(Int(n)))
            }
            return out
        case "skip":
            guard args.count >= 2 else { return [] }
            let ns = try JqEvaluator.evalNode(value, args[0], ctx)
            var out: [JqValue] = []
            for nv in ns {
                guard case .number(let n) = nv else { continue }
                if n < 0 { throw JqError("skip doesn't support negative count") }
                let r = try JqEvaluator.evalNode(value, args[1], ctx)
                out.append(contentsOf: r.dropFirst(Int(n)))
            }
            return out
        case "isempty":
            guard !args.isEmpty else { return [.bool(true)] }
            let r = (try? JqEvaluator.evalNode(value, args[0], ctx)) ?? []
            return [.bool(r.isEmpty)]
        case "isvalid":
            guard !args.isEmpty else { return [.bool(true)] }
            do {
                let r = try JqEvaluator.evalNode(value, args[0], ctx)
                return [.bool(!r.isEmpty)]
            } catch {
                return [.bool(false)]
            }
        case "until":
            guard args.count >= 2 else { return [value] }
            var cur = value
            for _ in 0..<ctx.maxIterations {
                let conds = try JqEvaluator.evalNode(cur, args[0], ctx)
                if conds.contains(where: { $0.isTruthy }) { return [cur] }
                let next = try JqEvaluator.evalNode(cur, args[1], ctx)
                if next.isEmpty { return [cur] }
                cur = next[0]
            }
            throw JqError("jq until: too many iterations")
        case "while":
            guard args.count >= 2 else { return [value] }
            var out: [JqValue] = []
            var cur = value
            for _ in 0..<ctx.maxIterations {
                let conds = try JqEvaluator.evalNode(cur, args[0], ctx)
                if !conds.contains(where: { $0.isTruthy }) { break }
                out.append(cur)
                let next = try JqEvaluator.evalNode(cur, args[1], ctx)
                if next.isEmpty { break }
                cur = next[0]
            }
            return out
        case "repeat":
            guard !args.isEmpty else { return [value] }
            var out: [JqValue] = []
            var cur = value
            for _ in 0..<ctx.maxIterations {
                out.append(cur)
                let next = try JqEvaluator.evalNode(cur, args[0], ctx)
                if next.isEmpty { break }
                cur = next[0]
            }
            return out
        default: return nil
        }
    }

    // MARK: - Index group

    static func indexBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "index":
            guard !args.isEmpty else { return [.null] }
            let needles = try JqEvaluator.evalNode(value, args[0], ctx)
            return needles.map { needle -> JqValue in
                switch (value, needle) {
                case (.string(let s), .string(let n)):
                    if n.isEmpty && s.isEmpty { return .null }
                    if let r = s.range(of: n) {
                        return .number(Double(s.distance(from: s.startIndex, to: r.lowerBound)))
                    }
                    return .null
                case (.array(let arr), .array(let nArr)):
                    for i in 0...max(0, arr.count - nArr.count) {
                        var ok = true
                        for j in 0..<nArr.count {
                            if i + j >= arr.count || !JqValue.jqEqual(arr[i + j], nArr[j]) { ok = false; break }
                        }
                        if ok && !nArr.isEmpty { return .number(Double(i)) }
                    }
                    return .null
                case (.array(let arr), _):
                    if let i = arr.firstIndex(where: { JqValue.jqEqual($0, needle) }) {
                        return .number(Double(i))
                    }
                    return .null
                default: return .null
                }
            }
        case "rindex":
            guard !args.isEmpty else { return [.null] }
            let needles = try JqEvaluator.evalNode(value, args[0], ctx)
            return needles.map { needle -> JqValue in
                switch (value, needle) {
                case (.string(let s), .string(let n)):
                    if let r = s.range(of: n, options: .backwards) {
                        return .number(Double(s.distance(from: s.startIndex, to: r.lowerBound)))
                    }
                    return .null
                case (.array(let arr), _):
                    for i in stride(from: arr.count - 1, through: 0, by: -1) {
                        if JqValue.jqEqual(arr[i], needle) { return .number(Double(i)) }
                    }
                    return .null
                default: return .null
                }
            }
        case "indices":
            guard !args.isEmpty else { return [.array([])] }
            let needles = try JqEvaluator.evalNode(value, args[0], ctx)
            return needles.map { needle -> JqValue in
                var result: [JqValue] = []
                switch (value, needle) {
                case (.string(let s), .string(let n)):
                    if n.isEmpty { return .array([]) }
                    var search = s.startIndex
                    while search < s.endIndex,
                          let r = s.range(of: n, range: search..<s.endIndex) {
                        result.append(.number(Double(s.distance(from: s.startIndex, to: r.lowerBound))))
                        search = s.index(after: r.lowerBound)
                    }
                case (.array(let arr), .array(let nArr)):
                    if nArr.isEmpty {
                        for i in 0...arr.count { result.append(.number(Double(i))) }
                    } else {
                        for i in 0...max(0, arr.count - nArr.count) {
                            var ok = true
                            for j in 0..<nArr.count {
                                if i + j >= arr.count || !JqValue.jqEqual(arr[i + j], nArr[j]) { ok = false; break }
                            }
                            if ok { result.append(.number(Double(i))) }
                        }
                    }
                case (.array(let arr), _):
                    for (i, v) in arr.enumerated() {
                        if JqValue.jqEqual(v, needle) { result.append(.number(Double(i))) }
                    }
                default: break
                }
                return .array(result)
            }
        default: return nil
        }
    }

    // MARK: - Path group

    static func pathBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "getpath":
            guard !args.isEmpty else { return [.null] }
            let paths = try JqEvaluator.evalNode(value, args[0], ctx)
            return paths.map { p -> JqValue in
                guard case .array(let pathArr) = p else { return .null }
                return JqPathOps.getPath(value, pathArr)
            }
        case "setpath":
            guard args.count >= 2 else { return [.null] }
            let paths = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .array(let path) = paths.first ?? .null else { return [.null] }
            let vs = try JqEvaluator.evalNode(value, args[1], ctx)
            return [try JqPathOps.setPath(value, path, vs.first ?? .null)]
        case "delpaths":
            guard !args.isEmpty else { return [value] }
            let lists = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .array(let paths) = lists.first ?? .array([]) else { return [value] }
            // Sort longest-first so child deletions don't shift parent indices.
            let sorted = paths.compactMap { v -> [JqValue]? in
                if case .array(let a) = v { return a } else { return nil }
            }.sorted { $0.count > $1.count }
            var result = value
            for path in sorted {
                result = try JqPathOps.deletePath(result, path)
            }
            return [result]
        case "path":
            guard !args.isEmpty else { return [.array([])] }
            var paths: [[JqValue]] = []
            try JqEvaluator.collectPaths(value, args[0], ctx, [], &paths)
            return paths.map { .array($0) }
        case "del":
            guard !args.isEmpty else { return [value] }
            var paths: [[JqValue]] = []
            try JqEvaluator.collectPaths(value, args[0], ctx, [], &paths)
            let sorted = paths.sorted { $0.count > $1.count }
            var result = value
            for path in sorted {
                result = try JqPathOps.deletePath(result, path)
            }
            return [result]
        case "pick":
            guard !args.isEmpty else { return [.null] }
            var allPaths: [[JqValue]] = []
            for arg in args {
                try JqEvaluator.collectPaths(value, arg, ctx, [], &allPaths)
            }
            var result: JqValue = .null
            for path in allPaths {
                let v = JqPathOps.getPath(value, path)
                result = try JqPathOps.setPath(result, path, v)
            }
            return [result]
        case "paths":
            var paths: [[JqValue]] = []
            func walk(_ v: JqValue, _ p: [JqValue]) {
                switch v {
                case .array(let arr):
                    for (i, item) in arr.enumerated() {
                        paths.append(p + [.number(Double(i))])
                        walk(item, p + [.number(Double(i))])
                    }
                case .object(let o):
                    for (k, item) in o {
                        paths.append(p + [.string(k)])
                        walk(item, p + [.string(k)])
                    }
                default: break
                }
            }
            walk(value, [])
            if !args.isEmpty {
                let filter = args[0]
                paths = try paths.filter { p in
                    let v = JqPathOps.getPath(value, p)
                    let r = try JqEvaluator.evalNode(v, filter, ctx)
                    return r.contains { $0.isTruthy }
                }
            }
            return paths.map { .array($0) }
        case "leaf_paths":
            var paths: [[JqValue]] = []
            func walk(_ v: JqValue, _ p: [JqValue]) {
                switch v {
                case .array(let arr):
                    for (i, item) in arr.enumerated() {
                        walk(item, p + [.number(Double(i))])
                    }
                case .object(let o):
                    for (k, item) in o {
                        walk(item, p + [.string(k)])
                    }
                default:
                    paths.append(p)
                }
            }
            walk(value, [])
            return paths.map { .array($0) }
        default: return nil
        }
    }

    // MARK: - Navigation group

    static func navigationBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "recurse":
            if args.isEmpty {
                var results: [JqValue] = []
                func walk(_ v: JqValue) {
                    results.append(v)
                    switch v {
                    case .array(let a): for x in a { walk(x) }
                    case .object(let o): for (_, x) in o { walk(x) }
                    default: break
                    }
                }
                walk(value)
                return results
            }
            var results: [JqValue] = []
            let condArg: JqAST? = args.count >= 2 ? args[1] : nil
            var depth = 0
            let maxDepth = 10000
            func walk(_ v: JqValue) throws {
                if depth > maxDepth { return }
                if let c = condArg {
                    let cs = try JqEvaluator.evalNode(v, c, ctx)
                    if !cs.contains(where: { $0.isTruthy }) { return }
                }
                results.append(v)
                let next = try JqEvaluator.evalNode(v, args[0], ctx)
                for n in next where !(n.isNull) {
                    depth += 1
                    try walk(n)
                    depth -= 1
                }
            }
            try walk(value)
            return results
        case "recurse_down":
            return try navigationBuiltin(value, "recurse", args, ctx)
        case "walk":
            guard !args.isEmpty else { return [value] }
            func go(_ v: JqValue) throws -> JqValue {
                let transformed: JqValue
                switch v {
                case .array(let a):
                    var out: [JqValue] = []
                    for item in a { out.append(try go(item)) }
                    transformed = .array(out)
                case .object(let o):
                    var out = JqObject()
                    for (k, item) in o { out[k] = try go(item) }
                    transformed = .object(out)
                default:
                    transformed = v
                }
                let r = try JqEvaluator.evalNode(transformed, args[0], ctx)
                return r.first ?? .null
            }
            return [try go(value)]
        case "transpose":
            guard case .array(let arr) = value else { return [.null] }
            var maxLen = 0
            for row in arr {
                if case .array(let r) = row, r.count > maxLen { maxLen = r.count }
            }
            var out: [JqValue] = []
            for i in 0..<maxLen {
                var col: [JqValue] = []
                for row in arr {
                    if case .array(let r) = row, i < r.count { col.append(r[i]) }
                    else { col.append(.null) }
                }
                out.append(.array(col))
            }
            return [.array(out)]
        case "combinations":
            if !args.isEmpty {
                let ns = try JqEvaluator.evalNode(value, args[0], ctx)
                guard case .number(let n) = ns.first ?? .null else { return [] }
                guard case .array(let arr) = value else { return [] }
                let count = Int(n)
                if count < 0 { return [] }
                if count == 0 { return [.array([])] }
                var out: [[JqValue]] = []
                func gen(_ cur: [JqValue], _ d: Int) {
                    if d == count { out.append(cur); return }
                    for item in arr { gen(cur + [item], d + 1) }
                }
                gen([], 0)
                return out.map { .array($0) }
            }
            guard case .array(let arr) = value else { return [] }
            for v in arr where !{ if case .array = v { return true } else { return false } }() { return [] }
            var out: [[JqValue]] = []
            func gen(_ idx: Int, _ cur: [JqValue]) {
                if idx == arr.count { out.append(cur); return }
                if case .array(let inner) = arr[idx] {
                    for item in inner { gen(idx + 1, cur + [item]) }
                }
            }
            gen(0, [])
            return out.map { .array($0) }
        case "parent":
            if ctx.currentPath.isEmpty { return [] }
            return [JqPathOps.getPath(ctx.root ?? value, Array(ctx.currentPath.dropLast()))]
        case "parents":
            var out: [JqValue] = []
            for i in stride(from: ctx.currentPath.count - 1, through: 0, by: -1) {
                out.append(JqPathOps.getPath(ctx.root ?? value, Array(ctx.currentPath.prefix(i))))
            }
            return [.array(out)]
        case "root":
            return [ctx.root ?? value]
        default: return nil
        }
    }

    // MARK: - SQL group

    static func sqlBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "IN":
            if args.isEmpty { return [.bool(false)] }
            if args.count == 1 {
                let stream = try JqEvaluator.evalNode(value, args[0], ctx)
                return [.bool(stream.contains { JqValue.jqEqual(value, $0) })]
            }
            let s1 = try JqEvaluator.evalNode(value, args[0], ctx)
            let s2 = try JqEvaluator.evalNode(value, args[1], ctx)
            for v in s1 {
                if s2.contains(where: { JqValue.jqEqual(v, $0) }) { return [.bool(true)] }
            }
            return [.bool(false)]
        case "INDEX":
            if args.isEmpty { return [.object(JqObject())] }
            if args.count == 1 {
                let stream = try JqEvaluator.evalNode(value, args[0], ctx)
                var obj = JqObject()
                for v in stream {
                    let k: String
                    if case .string(let s) = v { k = s }
                    else { k = JqFormatter.compact(v) }
                    obj[k] = v
                }
                return [.object(obj)]
            }
            if args.count == 2 {
                let stream = try JqEvaluator.evalNode(value, args[0], ctx)
                var obj = JqObject()
                for v in stream {
                    let keys = try JqEvaluator.evalNode(v, args[1], ctx)
                    if let k = keys.first {
                        let s: String
                        if case .string(let str) = k { s = str }
                        else { s = JqFormatter.compact(k) }
                        obj[s] = v
                    }
                }
                return [.object(obj)]
            }
            let stream = try JqEvaluator.evalNode(value, args[0], ctx)
            var obj = JqObject()
            for v in stream {
                let keys = try JqEvaluator.evalNode(v, args[1], ctx)
                let vals = try JqEvaluator.evalNode(v, args[2], ctx)
                if let k = keys.first, let val = vals.first {
                    let s: String
                    if case .string(let str) = k { s = str }
                    else { s = JqFormatter.compact(k) }
                    obj[s] = val
                }
            }
            return [.object(obj)]
        default: return nil
        }
    }

    // MARK: - Date group

    static func dateBuiltin(_ value: JqValue, _ name: String, _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "now":
            return [.number(Date().timeIntervalSince1970)]
        case "gmtime":
            guard case .number(let t) = value else { return [.null] }
            let date = Date(timeIntervalSince1970: t)
            let cal = Calendar(identifier: .gregorian)
            let c = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
            let weekday = (c.weekday ?? 1) - 1
            let yearday = computeDayOfYear(c)
            return [.array([
                .number(Double(c.year ?? 1970)),
                .number(Double((c.month ?? 1) - 1)),
                .number(Double(c.day ?? 1)),
                .number(Double(c.hour ?? 0)),
                .number(Double(c.minute ?? 0)),
                .number(Double(c.second ?? 0)),
                .number(Double(weekday)),
                .number(Double(yearday)),
            ])]
        case "mktime":
            guard case .array(let parts) = value, parts.count >= 6 else {
                throw JqError("mktime requires parsed datetime inputs")
            }
            var c = DateComponents()
            c.timeZone = TimeZone(identifier: "UTC")
            if case .number(let n) = parts[0] { c.year = Int(n) }
            if case .number(let n) = parts[1] { c.month = Int(n) + 1 }
            if case .number(let n) = parts[2] { c.day = Int(n) }
            if case .number(let n) = parts[3] { c.hour = Int(n) }
            if case .number(let n) = parts[4] { c.minute = Int(n) }
            if case .number(let n) = parts[5] { c.second = Int(n) }
            let cal = Calendar(identifier: .gregorian)
            guard let date = cal.date(from: c) else { throw JqError("invalid time") }
            return [.number(date.timeIntervalSince1970)]
        case "strftime":
            guard !args.isEmpty else { return [.null] }
            let fmts = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let fmt) = fmts.first ?? .null else {
                throw JqError("strftime requires a string format")
            }
            let date: Date
            switch value {
            case .number(let t): date = Date(timeIntervalSince1970: t)
            case .array(let parts) where parts.count >= 6:
                var c = DateComponents()
                c.timeZone = TimeZone(identifier: "UTC")
                if case .number(let n) = parts[0] { c.year = Int(n) }
                if case .number(let n) = parts[1] { c.month = Int(n) + 1 }
                if case .number(let n) = parts[2] { c.day = Int(n) }
                if case .number(let n) = parts[3] { c.hour = Int(n) }
                if case .number(let n) = parts[4] { c.minute = Int(n) }
                if case .number(let n) = parts[5] { c.second = Int(n) }
                guard let d = Calendar(identifier: .gregorian).date(from: c) else {
                    throw JqError("invalid time")
                }
                date = d
            default:
                throw JqError("strftime requires parsed datetime inputs")
            }
            return [.string(formatDate(date, fmt))]
        case "strptime":
            guard !args.isEmpty, case .string(let s) = value else {
                throw JqError("strptime requires a string input")
            }
            let fmts = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .string(let fmt) = fmts.first ?? .null else {
                throw JqError("strptime requires a string format")
            }
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = strftimeToICU(fmt)
            guard let date = formatter.date(from: s) else {
                throw JqError("date \"\(s)\" does not match format \"\(fmt)\"")
            }
            let cal = Calendar(identifier: .gregorian)
            let c = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
            let weekday = (c.weekday ?? 1) - 1
            let yearday = computeDayOfYear(c)
            return [.array([
                .number(Double(c.year ?? 1970)),
                .number(Double((c.month ?? 1) - 1)),
                .number(Double(c.day ?? 1)),
                .number(Double(c.hour ?? 0)),
                .number(Double(c.minute ?? 0)),
                .number(Double(c.second ?? 0)),
                .number(Double(weekday)),
                .number(Double(yearday)),
            ])]
        case "fromdate", "fromdateiso8601":
            guard case .string(let s) = value else {
                throw JqError("fromdate requires a string input")
            }
            let f = ISO8601DateFormatter()
            guard let d = f.date(from: s) else {
                throw JqError("date \"\(s)\" does not match format")
            }
            return [.number(d.timeIntervalSince1970)]
        case "todate", "todateiso8601":
            guard case .number(let t) = value else {
                throw JqError("todate requires a number input")
            }
            let f = ISO8601DateFormatter()
            return [.string(f.string(from: Date(timeIntervalSince1970: t)))]
        case "localtime":
            guard case .number(let t) = value else { return [.null] }
            let date = Date(timeIntervalSince1970: t)
            let cal = Calendar(identifier: .gregorian)
            let c = cal.dateComponents(in: .current, from: date)
            let weekday = (c.weekday ?? 1) - 1
            let yearday = computeDayOfYear(c)
            return [.array([
                .number(Double(c.year ?? 1970)),
                .number(Double((c.month ?? 1) - 1)),
                .number(Double(c.day ?? 1)),
                .number(Double(c.hour ?? 0)),
                .number(Double(c.minute ?? 0)),
                .number(Double(c.second ?? 0)),
                .number(Double(weekday)),
                .number(Double(yearday)),
            ])]
        default: return nil
        }
    }

    /// 0-based day of year. Pre-macOS 15 we don't have
    /// `DateComponents.dayOfYear` — compute it from year+month+day.
    static func computeDayOfYear(_ c: DateComponents) -> Int {
        guard let y = c.year, let m = c.month, let d = c.day else { return 0 }
        let daysBefore = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        var doy = daysBefore[max(0, min(11, m - 1))] + d - 1
        if m > 2 && isLeap(y) { doy += 1 }
        return doy
    }

    static func isLeap(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }

    static func strftimeToICU(_ fmt: String) -> String {
        var out = ""
        var i = fmt.startIndex
        while i < fmt.endIndex {
            let c = fmt[i]
            if c == "%" {
                i = fmt.index(after: i)
                if i >= fmt.endIndex { break }
                switch fmt[i] {
                case "Y": out += "yyyy"
                case "m": out += "MM"
                case "d": out += "dd"
                case "H": out += "HH"
                case "M": out += "mm"
                case "S": out += "ss"
                case "Z": out += "zzz"
                case "%": out += "%"
                default: out.append(fmt[i])
                }
                i = fmt.index(after: i)
            } else {
                if c.isLetter { out += "'\(c)'" } else { out.append(c) }
                i = fmt.index(after: i)
            }
        }
        return out
    }

    static func formatDate(_ date: Date, _ fmt: String) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEEE"
        let dayName = f.string(from: date)
        f.dateFormat = "MMMM"
        let monthName = f.string(from: date)
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
                case "A": out += dayName
                case "B": out += monthName
                case "Z": out += "UTC"
                case "%": out += "%"
                default: out.append(fmt[i])
                }
                i = fmt.index(after: i)
            } else {
                out.append(ch)
                i = fmt.index(after: i)
            }
        }
        _ = c
        return out
    }

    // MARK: - List of builtins (for `builtins` builtin)

    static let builtinsList: [String] = [
        "add/0", "all/0", "all/1", "all/2", "any/0", "any/1", "any/2",
        "arrays/0", "ascii/0", "ascii_downcase/0", "ascii_upcase/0",
        "atan2/2", "atan/0", "booleans/0", "bsearch/1", "builtins/0",
        "capture/1", "capture/2", "ceil/0", "combinations/0", "combinations/1",
        "contains/1", "cos/0", "cosh/0", "debug/0", "del/1", "delpaths/1",
        "empty/0", "endswith/1", "env/0", "error/0", "error/1", "exp/0",
        "exp10/0", "exp2/0", "explode/0", "fabs/0", "false/0", "first/0",
        "first/1", "flatten/0", "flatten/1", "floor/0", "fromdate/0",
        "fromdateiso8601/0", "fromjson/0", "fromstream/1", "from_entries/0",
        "frexp/0", "getpath/1", "gmtime/0", "group_by/1", "gsub/2", "gsub/3",
        "halt/0", "halt_error/0", "halt_error/1", "has/1", "hypot/1",
        "implode/0", "IN/1", "IN/2", "INDEX/1", "INDEX/2", "in/1",
        "index/1", "indices/1", "infinite/0", "input/0", "inputs/0",
        "input_line_number/0", "inside/1", "isempty/1", "isfinite/0",
        "isinfinite/0", "isnan/0", "isnormal/0", "isvalid/1",
        "iterables/0", "join/1", "keys/0", "keys_unsorted/0", "last/0",
        "last/1", "leaf_paths/0", "length/0", "limit/2", "localtime/0",
        "log/0", "log10/0", "log2/0", "ltrim/0", "ltrimstr/1",
        "map/1", "map_values/1", "match/1", "match/2", "max/0", "max_by/1",
        "min/0", "min_by/1", "mktime/0", "modf/0", "nan/0", "nearbyint/0",
        "not/0", "now/0", "nth/1", "nth/2", "null/0", "nulls/0",
        "numbers/0", "objects/0", "parent/0", "parents/0", "path/1",
        "paths/0", "paths/1", "pick/1", "pow/2", "range/1", "range/2",
        "range/3", "recurse/0", "recurse/1", "recurse_down/0", "repeat/1",
        "reverse/0", "rindex/1", "root/0", "round/0", "rtrim/0",
        "rtrimstr/1", "scalars/0", "scan/1", "scan/2", "select/1",
        "setpath/2", "significand/0", "sin/0", "sinh/0", "skip/2",
        "sort/0", "sort_by/1", "split/1", "splits/1", "splits/2",
        "sqrt/0", "startswith/1", "stderr/0", "strftime/1", "strings/0",
        "strptime/1", "sub/2", "sub/3", "tan/0", "tanh/0", "test/1",
        "test/2", "to_entries/0", "toboolean/0", "todate/0",
        "todateiso8601/0", "tojson/0", "tonumber/0", "tostream/0",
        "tostring/0", "transpose/0", "trim/0", "true/0", "trimstr/1",
        "truncate_stream/1", "type/0", "unique/0", "unique_by/1",
        "until/2", "utf8bytelength/0", "values/0", "walk/1", "while/2",
        "with_entries/1",
    ]
}
