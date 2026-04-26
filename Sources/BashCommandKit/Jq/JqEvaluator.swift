import Foundation

/// Evaluation context: variable bindings, user-defined functions,
/// document root for parent/path tracking, plus iteration limits.
public final class JqContext {
    public var vars: [String: JqValue]
    public var env: [String: String]
    public var funcs: [String: JqFunc]
    public var labels: Set<String>
    public var root: JqValue?
    public var currentPath: [JqValue]
    public var maxIterations: Int

    public init(env: [String: String] = [:], maxIterations: Int = 1_000_000) {
        self.vars = [:]
        self.env = env
        self.funcs = [:]
        self.labels = []
        self.root = nil
        self.currentPath = []
        self.maxIterations = maxIterations
    }

    /// Snapshot used when forking the evaluator into a sub-scope so
    /// mutations to vars/funcs don't leak back to the caller.
    func fork() -> JqContext {
        let c = JqContext(env: env, maxIterations: maxIterations)
        c.vars = vars
        c.funcs = funcs
        c.labels = labels
        c.root = root
        c.currentPath = currentPath
        return c
    }
}

public struct JqFunc {
    public let params: [String]
    public let body: JqAST
    /// Lexical closure: function table at definition time.
    public let closure: [String: JqFunc]
}

/// Top-level evaluator. Each AST node returns a `[JqValue]` because jq
/// filters are streams (zero, one, or many results).
public struct JqEvaluator {

    public static func evaluate(_ value: JqValue,
                                _ ast: JqAST,
                                ctx: JqContext) throws -> [JqValue] {
        if ctx.root == nil {
            ctx.root = value
            ctx.currentPath = []
        }
        return try evalNode(value, ast, ctx)
    }

    static func evalNode(_ value: JqValue, _ ast: JqAST, _ ctx: JqContext) throws -> [JqValue] {
        switch ast {
        case .identity:
            return [value]

        case .recurse:
            var results: [JqValue] = []
            func walk(_ v: JqValue) {
                results.append(v)
                switch v {
                case .array(let xs): for x in xs { walk(x) }
                case .object(let o): for (_, x) in o { walk(x) }
                default: break
                }
            }
            walk(value)
            return results

        case .field(let name, let base):
            let bases = try base.map { try evalNode(value, $0, ctx) } ?? [value]
            var out: [JqValue] = []
            for b in bases {
                switch b {
                case .object(let o): out.append(o[name] ?? .null)
                case .null: out.append(.null)
                default:
                    throw JqError("Cannot index \(b.typeName) with \"\(name)\"")
                }
            }
            return out

        case .index(let indexExpr, let base):
            let bases = try base.map { try evalNode(value, $0, ctx) } ?? [value]
            var out: [JqValue] = []
            for b in bases {
                let idxs = try evalNode(b, indexExpr, ctx)
                for idx in idxs {
                    out.append(try indexInto(b, idx))
                }
            }
            return out

        case .slice(let s, let e, let base):
            let bases = try base.map { try evalNode(value, $0, ctx) } ?? [value]
            var out: [JqValue] = []
            for b in bases {
                if case .null = b { out.append(.null); continue }
                let starts: [JqValue] = try s.map { try evalNode(value, $0, ctx) } ?? [.number(0)]
                let len: Int
                switch b {
                case .array(let a): len = a.count
                case .string(let str): len = Array(str).count
                default: throw JqError("Cannot slice \(b.typeName)")
                }
                let ends: [JqValue] = try e.map { try evalNode(value, $0, ctx) } ?? [.number(Double(len))]
                for sv in starts {
                    for ev in ends {
                        out.append(try sliceValue(b, sv, ev, length: len))
                    }
                }
            }
            return out

        case .iterate(let base):
            let bases = try base.map { try evalNode(value, $0, ctx) } ?? [value]
            var out: [JqValue] = []
            for b in bases {
                switch b {
                case .array(let arr): out.append(contentsOf: arr)
                case .object(let obj): for (_, v) in obj { out.append(v) }
                case .null: throw JqError("Cannot iterate over null (null)")
                default: throw JqError("Cannot iterate over \(b.typeName)")
                }
            }
            return out

        case .pipe(let l, let r):
            let lefts = try evalNode(value, l, ctx)
            let leftPath = extractPath(l)
            var out: [JqValue] = []
            for v in lefts {
                let saved = ctx.currentPath
                if let p = leftPath {
                    ctx.currentPath = ctx.currentPath + p
                }
                defer { ctx.currentPath = saved }
                do {
                    out.append(contentsOf: try evalNode(v, r, ctx))
                } catch var brk as JqBreak {
                    brk.partial = out + brk.partial
                    throw brk
                }
            }
            return out

        case .comma(let l, let r):
            let left = try evalNode(value, l, ctx)
            let right = try evalNode(value, r, ctx)
            return left + right

        case .literal(let v):
            return [v]

        case .array(let body):
            guard let body else { return [.array([])] }
            let elems = try evalNode(value, body, ctx)
            return [.array(elems)]

        case .object(let entries):
            return try evalObject(value, entries, ctx)

        case .paren(let inner):
            return try evalNode(value, inner, ctx)

        case .binaryOp(let op, let l, let r):
            return try evalBinary(value, op, l, r, ctx)

        case .unaryOp(let op, let operand):
            let vals = try evalNode(value, operand, ctx)
            return try vals.map { v -> JqValue in
                switch op {
                case .neg:
                    if case .number(let n) = v { return .number(-n) }
                    if case .null = v { return .null }
                    throw JqError("\(v.typeName) cannot be negated")
                case .not:
                    return .bool(!v.isTruthy)
                }
            }

        case .cond(let cond, let thenBranch, let elifs, let else_):
            let conds = try evalNode(value, cond, ctx)
            var out: [JqValue] = []
            for c in conds {
                if c.isTruthy {
                    out.append(contentsOf: try evalNode(value, thenBranch, ctx))
                } else {
                    var matched = false
                    for (ec, et) in elifs {
                        let ecvals = try evalNode(value, ec, ctx)
                        if ecvals.contains(where: { $0.isTruthy }) {
                            out.append(contentsOf: try evalNode(value, et, ctx))
                            matched = true
                            break
                        }
                    }
                    if !matched {
                        if let elseExpr = else_ {
                            out.append(contentsOf: try evalNode(value, elseExpr, ctx))
                        } else {
                            out.append(value)
                        }
                    }
                }
            }
            return out

        case .try_(let body, let catch_):
            do {
                return try evalNode(value, body, ctx)
            } catch let e as JqBreak {
                throw e
            } catch let e as JqThrown {
                if let c = catch_ {
                    return try evalNode(e.value, c, ctx)
                }
                return []
            } catch let e as JqError {
                if let c = catch_ {
                    return try evalNode(.string(e.message), c, ctx)
                }
                return []
            } catch {
                if let c = catch_ {
                    return try evalNode(.string(String(describing: error)), c, ctx)
                }
                return []
            }

        case .call(let name, let args):
            return try JqBuiltins.evaluate(value, name: name, args: args, ctx: ctx)

        case .varBind(let pat, let alts, let valueAST, let body):
            let values = try evalNode(value, valueAST, ctx)
            var out: [JqValue] = []
            for v in values {
                let patternsToTry = [pat] + alts
                var bound: JqContext? = nil
                for p in patternsToTry {
                    if let nctx = bindPattern(ctx, p, v) {
                        bound = nctx
                        break
                    }
                }
                guard let nctx = bound else { continue }
                out.append(contentsOf: try evalNode(value, body, nctx))
            }
            return out

        case .varRef(let name):
            if name == "$ENV" || name == "$__loc__" {
                if name == "$ENV" {
                    var obj = JqObject()
                    for (k, v) in ctx.env { obj[k] = .string(v) }
                    return [.object(obj)]
                }
                var obj = JqObject()
                obj["file"] = .string("<top-level>")
                obj["line"] = .number(1)
                return [.object(obj)]
            }
            if let v = ctx.vars[name] { return [v] }
            // jq throws "$name is not defined" — but in many places callers
            // catch via try/?, so prefer error.
            throw JqError("$\(String(name.dropFirst())) is not defined")

        case .optional(let expr):
            do { return try evalNode(value, expr, ctx) }
            catch _ as JqBreak { throw JqBreak(label: "") }  // unreachable; rethrow only for label flow
            catch { return [] }

        case .stringInterp(let parts):
            return [evalStringInterp(value, parts, ctx)]

        case .updateOp(let op, let path, let valueExpr):
            return [try applyUpdate(value, path, op, valueExpr, ctx)]

        case .reduce(let expr, let pat, let init_, let update):
            let items = try evalNode(value, expr, ctx)
            var acc = (try evalNode(value, init_, ctx)).first ?? .null
            for item in items {
                guard let nctx = bindPattern(ctx, pat, item) else { continue }
                let next = try evalNode(acc, update, nctx)
                acc = next.first ?? .null
            }
            return [acc]

        case .foreach(let expr, let pat, let init_, let update, let extract):
            let items = try evalNode(value, expr, ctx)
            var state = (try evalNode(value, init_, ctx)).first ?? .null
            var out: [JqValue] = []
            for item in items {
                guard let nctx = bindPattern(ctx, pat, item) else { continue }
                let next = try evalNode(state, update, nctx)
                state = next.first ?? .null
                if let ex = extract {
                    out.append(contentsOf: try evalNode(state, ex, nctx))
                } else {
                    out.append(state)
                }
            }
            return out

        case .label(let name, let body):
            ctx.labels.insert(name)
            defer { ctx.labels.remove(name) }
            do {
                return try evalNode(value, body, ctx)
            } catch let brk as JqBreak where brk.label == name {
                return brk.partial
            }

        case .break_(let name):
            throw JqBreak(label: name)

        case .def(let name, let params, let funcBody, let body):
            let key = "\(name)/\(params.count)"
            let fn = JqFunc(params: params, body: funcBody, closure: ctx.funcs)
            let saved = ctx.funcs
            ctx.funcs[key] = fn
            defer { ctx.funcs = saved }
            return try evalNode(value, body, ctx)

        case .format(let name, let interp):
            return try JqFormatBuiltins.evaluate(value, name: name, interp: interp, ctx: ctx)
        }
    }

    // MARK: - Indexing helpers

    static func indexInto(_ b: JqValue, _ idx: JqValue) throws -> JqValue {
        switch (b, idx) {
        case (.null, _): return .null
        case (.array(let arr), .number(let n)):
            if n.isNaN { return .null }
            let i = Int(n.rounded(.towardZero))
            let real = i < 0 ? arr.count + i : i
            return real >= 0 && real < arr.count ? arr[real] : .null
        case (.object(let o), .string(let k)):
            return o[k] ?? .null
        case (.array, _):
            throw JqError("Cannot index array with \(idx.typeName)")
        case (.object, _):
            throw JqError("Cannot index object with \(idx.typeName)")
        default:
            throw JqError("Cannot index \(b.typeName) with \(idx.typeName)")
        }
    }

    static func sliceValue(_ b: JqValue, _ sv: JqValue, _ ev: JqValue, length: Int) throws -> JqValue {
        let sNum: Double
        if case .number(let n) = sv { sNum = n.isNaN ? 0 : n }
        else if case .null = sv { sNum = 0 }
        else { throw JqError("Slice bound is not a number") }
        let eNum: Double
        if case .number(let n) = ev { eNum = n.isNaN ? Double(length) : n }
        else if case .null = ev { eNum = Double(length) }
        else { throw JqError("Slice bound is not a number") }
        let startRaw = sNum.rounded(.down)
        let endRaw = eNum.rounded(.up)
        let start = normalize(Int(startRaw), len: length)
        let end = normalize(Int(endRaw), len: length)
        switch b {
        case .array(let arr):
            if start >= end { return .array([]) }
            return .array(Array(arr[start..<end]))
        case .string(let s):
            let chars = Array(s)
            if start >= end { return .string("") }
            return .string(String(chars[start..<end]))
        default:
            throw JqError("Cannot slice \(b.typeName)")
        }
    }

    static func normalize(_ idx: Int, len: Int) -> Int {
        var i = idx
        if i < 0 { i = max(0, len + i) }
        return min(max(i, 0), len)
    }

    // MARK: - Object construction

    static func evalObject(_ value: JqValue, _ entries: [JqObjectEntry], _ ctx: JqContext) throws -> [JqValue] {
        var results: [JqObject] = [JqObject()]
        for entry in entries {
            let keys: [String]
            switch entry.key {
            case .literal(let s): keys = [s]
            case .computed(let expr):
                let ks = try evalNode(value, expr, ctx)
                var out: [String] = []
                for k in ks {
                    guard case .string(let s) = k else {
                        throw JqError("Object key must be a string")
                    }
                    out.append(s)
                }
                keys = out
            }
            let values = try evalNode(value, entry.value, ctx)
            var newResults: [JqObject] = []
            for r in results {
                for k in keys {
                    for v in values {
                        var nr = r
                        nr[k] = v
                        newResults.append(nr)
                    }
                }
            }
            results = newResults
        }
        return results.map { .object($0) }
    }

    // MARK: - Binary operators

    static func evalBinary(_ value: JqValue, _ op: JqBinaryOp,
                           _ l: JqAST, _ r: JqAST, _ ctx: JqContext) throws -> [JqValue] {
        // Short-circuit logical operators
        if op == .and {
            let ls = try evalNode(value, l, ctx)
            var out: [JqValue] = []
            for lv in ls {
                if !lv.isTruthy { out.append(.bool(false)); continue }
                let rs = try evalNode(value, r, ctx)
                for rv in rs { out.append(.bool(rv.isTruthy)) }
            }
            return out
        }
        if op == .or {
            let ls = try evalNode(value, l, ctx)
            var out: [JqValue] = []
            for lv in ls {
                if lv.isTruthy { out.append(.bool(true)); continue }
                let rs = try evalNode(value, r, ctx)
                for rv in rs { out.append(.bool(rv.isTruthy)) }
            }
            return out
        }
        if op == .alt {
            let ls = try evalNode(value, l, ctx)
            let nonNull = ls.filter { v in
                if case .null = v { return false }
                if case .bool(false) = v { return false }
                return true
            }
            if !nonNull.isEmpty { return nonNull }
            return try evalNode(value, r, ctx)
        }
        let lefts = try evalNode(value, l, ctx)
        let rights = try evalNode(value, r, ctx)
        var out: [JqValue] = []
        for lv in lefts {
            for rv in rights {
                out.append(try applyBinary(op, lv, rv))
            }
        }
        return out
    }

    static func applyBinary(_ op: JqBinaryOp, _ l: JqValue, _ r: JqValue) throws -> JqValue {
        switch op {
        case .add:
            switch (l, r) {
            case (.null, _): return r
            case (_, .null): return l
            case (.number(let a), .number(let b)): return .number(a + b)
            case (.string(let a), .string(let b)): return .string(a + b)
            case (.array(let a), .array(let b)): return .array(a + b)
            case (.object(var a), .object(let b)):
                for (k, v) in b { a[k] = v }
                return .object(a)
            default:
                throw JqError("\(l.typeName) and \(r.typeName) cannot be added")
            }
        case .sub:
            switch (l, r) {
            case (.number(let a), .number(let b)): return .number(a - b)
            case (.array(let a), .array(let b)):
                return .array(a.filter { x in !b.contains { JqValue.jqEqual($0, x) } })
            default:
                throw JqError("\(l.typeName) and \(r.typeName) cannot be subtracted")
            }
        case .mul:
            switch (l, r) {
            case (.number(let a), .number(let b)): return .number(a * b)
            case (.string(let a), .number(let b)):
                if b.isNaN || b <= 0 { return .null }
                return .string(String(repeating: a, count: Int(b)))
            case (.string(let a), .string(let b)):
                // jq's "splat join" semantics: split a by b
                return .array(a.components(separatedBy: b).map { .string($0) })
            case (.null, _), (_, .null): return .null
            case (.object(let a), .object(let b)):
                return .object(deepMerge(a, b))
            default:
                throw JqError("\(l.typeName) and \(r.typeName) cannot be multiplied")
            }
        case .div:
            switch (l, r) {
            case (.number(let a), .number(let b)):
                if b == 0 {
                    throw JqError("number (\(JqValue.formatDouble(a))) and number (\(JqValue.formatDouble(b))) cannot be divided because the divisor is zero")
                }
                return .number(a / b)
            case (.string(let a), .string(let b)):
                if b.isEmpty { return .array([]) }
                return .array(a.components(separatedBy: b).map { .string($0) })
            default:
                throw JqError("\(l.typeName) and \(r.typeName) cannot be divided")
            }
        case .mod:
            switch (l, r) {
            case (.number(let a), .number(let b)):
                if b == 0 {
                    throw JqError("number (\(JqValue.formatDouble(a))) and number (\(JqValue.formatDouble(b))) cannot be divided (remainder) because the divisor is zero")
                }
                return .number(Double(Int(a).quotientAndRemainder(dividingBy: Int(b)).remainder))
            default:
                throw JqError("\(l.typeName) and \(r.typeName) cannot be divided (mod)")
            }
        case .eq: return .bool(JqValue.jqEqual(l, r))
        case .ne: return .bool(!JqValue.jqEqual(l, r))
        case .lt: return .bool(JqValue.jqCompare(l, r) < 0)
        case .le: return .bool(JqValue.jqCompare(l, r) <= 0)
        case .gt: return .bool(JqValue.jqCompare(l, r) > 0)
        case .ge: return .bool(JqValue.jqCompare(l, r) >= 0)
        case .and, .or, .alt:
            return .null  // handled above
        }
    }

    static func deepMerge(_ a: JqObject, _ b: JqObject) -> JqObject {
        var result = a
        for (k, v) in b {
            if let existing = result[k],
               case .object(let ea) = existing,
               case .object(let eb) = v {
                result[k] = .object(deepMerge(ea, eb))
            } else {
                result[k] = v
            }
        }
        return result
    }

    // MARK: - Variables / patterns

    static func bindPattern(_ ctx: JqContext, _ pat: JqPattern, _ value: JqValue) -> JqContext? {
        switch pat {
        case .variable(let name):
            let nctx = ctx.fork()
            nctx.vars[name] = value
            return nctx
        case .array(let elems):
            guard case .array(let arr) = value else { return nil }
            var nctx = ctx
            for (i, e) in elems.enumerated() {
                let elemValue = i < arr.count ? arr[i] : .null
                guard let r = bindPattern(nctx, e, elemValue) else { return nil }
                nctx = r
            }
            return nctx
        case .object(let fields):
            guard case .object(let obj) = value else { return nil }
            var nctx = ctx
            for f in fields {
                let key: String
                switch f.key {
                case .literal(let s): key = s
                case .computed(let expr):
                    guard let kv = (try? evalNode(value, expr, nctx))?.first,
                          case .string(let s) = kv else { return nil }
                    key = s
                }
                let fv = obj[key] ?? .null
                if let kv = f.keyVar {
                    let nc = nctx.fork()
                    nc.vars[kv] = fv
                    nctx = nc
                }
                guard let r = bindPattern(nctx, f.pattern, fv) else { return nil }
                nctx = r
            }
            return nctx
        }
    }

    // MARK: - String interpolation

    static func evalStringInterp(_ value: JqValue, _ parts: [JqStringPart], _ ctx: JqContext) -> JqValue {
        var out = ""
        for part in parts {
            switch part {
            case .literal(let s): out += s
            case .interp(let expr):
                let vs = (try? evalNode(value, expr, ctx)) ?? []
                for v in vs {
                    switch v {
                    case .string(let s): out += s
                    default: out += JqFormatter.compact(v)
                    }
                }
            }
        }
        return .string(out)
    }

    // MARK: - Update operations

    static func applyUpdate(_ root: JqValue, _ pathExpr: JqAST, _ op: JqUpdateOp,
                            _ valueExpr: JqAST, _ ctx: JqContext) throws -> JqValue {
        var paths: [[JqValue]] = []
        try collectPaths(root, pathExpr, ctx, [], &paths)
        var result = root
        // Sort longest first so child updates don't get clobbered when
        // we later set parent paths.
        let sorted = paths.sorted { $0.count > $1.count }
        for path in sorted {
            let current = JqPathOps.getPath(result, path)
            let newVal: JqValue
            switch op {
            case .assign:
                let vs = try evalNode(root, valueExpr, ctx)
                newVal = vs.first ?? .null
            case .pipeAssign:
                let vs = try evalNode(current, valueExpr, ctx)
                newVal = vs.first ?? .null
            case .addAssign:
                let vs = try evalNode(root, valueExpr, ctx)
                let v = vs.first ?? .null
                newVal = try applyBinary(.add, current, v)
            case .subAssign:
                let vs = try evalNode(root, valueExpr, ctx)
                let v = vs.first ?? .null
                newVal = try applyBinary(.sub, current, v)
            case .mulAssign:
                let vs = try evalNode(root, valueExpr, ctx)
                let v = vs.first ?? .null
                newVal = try applyBinary(.mul, current, v)
            case .divAssign:
                let vs = try evalNode(root, valueExpr, ctx)
                let v = vs.first ?? .null
                newVal = try applyBinary(.div, current, v)
            case .modAssign:
                let vs = try evalNode(root, valueExpr, ctx)
                let v = vs.first ?? .null
                newVal = try applyBinary(.mod, current, v)
            case .altAssign:
                if case .null = current {
                    let vs = try evalNode(root, valueExpr, ctx)
                    newVal = vs.first ?? .null
                } else if case .bool(false) = current {
                    let vs = try evalNode(root, valueExpr, ctx)
                    newVal = vs.first ?? .null
                } else {
                    newVal = current
                }
            }
            result = try JqPathOps.setPath(result, path, newVal)
        }
        return result
    }

    // MARK: - Path collection

    static func extractPath(_ ast: JqAST) -> [JqValue]? {
        switch ast {
        case .identity: return []
        case .field(let name, let base):
            var p = base.flatMap(extractPath) ?? []
            p.append(.string(name))
            return base == nil || extractPath(base!) != nil ? p : nil
        case .index(let idx, let base):
            if case .literal(let v) = idx {
                var p = base.flatMap(extractPath) ?? []
                p.append(v)
                return base == nil || extractPath(base!) != nil ? p : nil
            }
            return nil
        case .pipe(let l, let r):
            guard let lp = extractPath(l), let rp = extractPath(r) else { return nil }
            return lp + rp
        default:
            return nil
        }
    }

    /// Collect all concrete paths produced by evaluating `expr` against
    /// `value`. Used by `path/1`, `del/1`, update operators.
    static func collectPaths(_ value: JqValue, _ expr: JqAST, _ ctx: JqContext,
                             _ basePath: [JqValue],
                             _ paths: inout [[JqValue]]) throws {
        switch expr {
        case .identity:
            paths.append(basePath)
        case .recurse:
            func walk(_ v: JqValue, _ p: [JqValue]) {
                paths.append(p)
                switch v {
                case .array(let arr):
                    for (i, item) in arr.enumerated() {
                        walk(item, p + [.number(Double(i))])
                    }
                case .object(let o):
                    for (k, v) in o {
                        walk(v, p + [.string(k)])
                    }
                default: break
                }
            }
            walk(value, basePath)
        case .field(let name, let base):
            if let b = base {
                var bp: [[JqValue]] = []
                try collectPaths(value, b, ctx, basePath, &bp)
                for p in bp {
                    paths.append(p + [.string(name)])
                }
            } else {
                paths.append(basePath + [.string(name)])
            }
        case .index(let idx, let base):
            let bases: [[JqValue]]
            if let b = base {
                var bp: [[JqValue]] = []
                try collectPaths(value, b, ctx, basePath, &bp)
                bases = bp
            } else {
                bases = [basePath]
            }
            for bp in bases {
                let target = JqPathOps.getPath(value, bp.dropFirst(basePath.count).map { $0 })
                let idxs = try evalNode(target, idx, ctx)
                for iv in idxs {
                    paths.append(bp + [iv])
                }
            }
        case .iterate(let base):
            let bases: [[JqValue]]
            if let b = base {
                var bp: [[JqValue]] = []
                try collectPaths(value, b, ctx, basePath, &bp)
                bases = bp
            } else {
                bases = [basePath]
            }
            for bp in bases {
                let relative = Array(bp.dropFirst(basePath.count))
                let target = JqPathOps.getPath(value, relative)
                switch target {
                case .array(let arr):
                    for i in 0..<arr.count {
                        paths.append(bp + [.number(Double(i))])
                    }
                case .object(let o):
                    for k in o.keys {
                        paths.append(bp + [.string(k)])
                    }
                default: break
                }
            }
        case .slice(let s, let e, let base):
            let bases: [[JqValue]]
            if let b = base {
                var bp: [[JqValue]] = []
                try collectPaths(value, b, ctx, basePath, &bp)
                bases = bp
            } else {
                bases = [basePath]
            }
            for bp in bases {
                let relative = Array(bp.dropFirst(basePath.count))
                let target = JqPathOps.getPath(value, relative)
                guard case .array(let arr) = target else { continue }
                let len = arr.count
                let starts: [JqValue] = try s.map { try evalNode(value, $0, ctx) } ?? [.number(0)]
                let ends: [JqValue] = try e.map { try evalNode(value, $0, ctx) } ?? [.number(Double(len))]
                for sv in starts {
                    for ev in ends {
                        var sNum = 0.0
                        if case .number(let n) = sv { sNum = n }
                        var eNum = Double(len)
                        if case .number(let n) = ev { eNum = n }
                        var slice = JqObject()
                        slice["start"] = .number(sNum)
                        slice["end"] = .number(eNum)
                        paths.append(bp + [.object(slice)])
                    }
                }
            }
        case .pipe(let l, let r):
            var leftPaths: [[JqValue]] = []
            try collectPaths(value, l, ctx, basePath, &leftPaths)
            for lp in leftPaths {
                let target = JqPathOps.getPath(value, Array(lp.dropFirst(basePath.count)))
                try collectPaths(target, r, ctx, lp, &paths)
            }
        case .comma(let l, let r):
            try collectPaths(value, l, ctx, basePath, &paths)
            try collectPaths(value, r, ctx, basePath, &paths)
        case .optional(let inner):
            do {
                try collectPaths(value, inner, ctx, basePath, &paths)
            } catch { /* swallow */ }
        case .try_(let body, _):
            do {
                try collectPaths(value, body, ctx, basePath, &paths)
            } catch { /* swallow */ }
        case .paren(let inner):
            try collectPaths(value, inner, ctx, basePath, &paths)
        case .call(let name, _) where name == "first":
            paths.append(basePath + [.number(0)])
        case .call(let name, _) where name == "last":
            let target = JqPathOps.getPath(value, [])
            if case .array(let arr) = target {
                paths.append(basePath + [.number(Double(arr.count - 1))])
            }
        case .cond(let cond, let thenB, let elifs, let else_):
            let conds = try evalNode(value, cond, ctx)
            for c in conds {
                if c.isTruthy {
                    try collectPaths(value, thenB, ctx, basePath, &paths)
                } else {
                    var matched = false
                    for (ec, et) in elifs {
                        let ecs = try evalNode(value, ec, ctx)
                        if ecs.contains(where: { $0.isTruthy }) {
                            try collectPaths(value, et, ctx, basePath, &paths)
                            matched = true
                            break
                        }
                    }
                    if !matched, let e = else_ {
                        try collectPaths(value, e, ctx, basePath, &paths)
                    } else if !matched {
                        paths.append(basePath)
                    }
                }
            }
        default:
            // Fallback: just evaluate; if it produces values, treat as
            // identity path (best-effort for unsupported AST shapes).
            let r = try evalNode(value, expr, ctx)
            if !r.isEmpty { paths.append(basePath) }
        }
    }
}
