import Foundation

// Per-AST-case handlers split out from JqEvaluator.evalNode to keep that
// dispatch switch short. Each helper assumes the matching `ast` shape.

extension JqEvaluator {

    static func evalRecurse(_ value: JqValue) -> [JqValue] {
        var results: [JqValue] = []
        func walk(_ item: JqValue) {
            results.append(item)
            switch item {
            case .array(let arr): for child in arr { walk(child) }
            case .object(let obj): for (_, child) in obj { walk(child) }
            default: break
            }
        }
        walk(value)
        return results
    }

    static func evalField(_ value: JqValue,
                          name: String,
                          base: JqAST?,
                          ctx: JqContext) throws -> [JqValue] {
        let bases = try base.map { try evalNode(value, $0, ctx) } ?? [value]
        var out: [JqValue] = []
        for baseVal in bases {
            switch baseVal {
            case .object(let obj): out.append(obj[name] ?? .null)
            case .null: out.append(.null)
            default:
                throw JqError("Cannot index \(baseVal.typeName) with \"\(name)\"")
            }
        }
        return out
    }

    static func evalIndex(_ value: JqValue,
                          indexExpr: JqAST,
                          base: JqAST?,
                          ctx: JqContext) throws -> [JqValue] {
        let bases = try base.map { try evalNode(value, $0, ctx) } ?? [value]
        var out: [JqValue] = []
        for baseVal in bases {
            let idxs = try evalNode(baseVal, indexExpr, ctx)
            for idx in idxs {
                out.append(try indexInto(baseVal, idx))
            }
        }
        return out
    }

    static func evalSlice(_ value: JqValue,
                          startAST: JqAST?,
                          endAST: JqAST?,
                          base: JqAST?,
                          ctx: JqContext) throws -> [JqValue] {
        let bases = try base.map { try evalNode(value, $0, ctx) } ?? [value]
        var out: [JqValue] = []
        for baseVal in bases {
            if case .null = baseVal { out.append(.null); continue }
            let starts: [JqValue] = try startAST.map { try evalNode(value, $0, ctx) } ?? [.number(0)]
            let len: Int
            switch baseVal {
            case .array(let arr): len = arr.count
            case .string(let str): len = Array(str).count
            default: throw JqError("Cannot slice \(baseVal.typeName)")
            }
            let ends: [JqValue] = try endAST.map { try evalNode(value, $0, ctx) }
                ?? [.number(Double(len))]
            for startVal in starts {
                for endVal in ends {
                    out.append(try sliceValue(baseVal, startVal, endVal, length: len))
                }
            }
        }
        return out
    }

    static func evalIterate(_ value: JqValue,
                            base: JqAST?,
                            ctx: JqContext) throws -> [JqValue] {
        let bases = try base.map { try evalNode(value, $0, ctx) } ?? [value]
        var out: [JqValue] = []
        for baseVal in bases {
            switch baseVal {
            case .array(let arr): out.append(contentsOf: arr)
            case .object(let obj): for (_, child) in obj { out.append(child) }
            case .null: throw JqError("Cannot iterate over null (null)")
            default: throw JqError("Cannot iterate over \(baseVal.typeName)")
            }
        }
        return out
    }

    static func evalPipe(_ value: JqValue,
                         left: JqAST,
                         right: JqAST,
                         ctx: JqContext) throws -> [JqValue] {
        let lefts = try evalNode(value, left, ctx)
        let leftPath = extractPath(left)
        var out: [JqValue] = []
        for item in lefts {
            let saved = ctx.currentPath
            if let path = leftPath {
                ctx.currentPath += path
            }
            defer { ctx.currentPath = saved }
            do {
                out.append(contentsOf: try evalNode(item, right, ctx))
            } catch var brk as JqBreak {
                brk.partial = out + brk.partial
                throw brk
            }
        }
        return out
    }

    static func evalUnary(_ value: JqValue,
                          unaryOp: JqUnaryOp,
                          operand: JqAST,
                          ctx: JqContext) throws -> [JqValue] {
        let vals = try evalNode(value, operand, ctx)
        return try vals.map { item -> JqValue in
            switch unaryOp {
            case .neg:
                if case .number(let num) = item { return .number(-num) }
                if case .null = item { return .null }
                throw JqError("\(item.typeName) cannot be negated")
            case .not:
                return .bool(!item.isTruthy)
            }
        }
    }

    static func evalCond(_ value: JqValue, ast: JqAST, ctx: JqContext) throws -> [JqValue] {
        // AST label `else_` mirrors a Swift keyword; rename would break public AST.
        // swiftlint:disable:next identifier_name
        guard case .cond(let cond, let thenBranch, let elifs, let else_) = ast else { return [] }
        let conds = try evalNode(value, cond, ctx)
        var out: [JqValue] = []
        for condVal in conds {
            if condVal.isTruthy {
                out.append(contentsOf: try evalNode(value, thenBranch, ctx))
                continue
            }
            var matched = false
            for (elifCond, elifThen) in elifs {
                let elifVals = try evalNode(value, elifCond, ctx)
                if elifVals.contains(where: { $0.isTruthy }) {
                    out.append(contentsOf: try evalNode(value, elifThen, ctx))
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
        return out
    }

    static func evalTry(_ value: JqValue, ast: JqAST, ctx: JqContext) throws -> [JqValue] {
        // AST label `catch_` mirrors a Swift keyword; rename would break public AST.
        // swiftlint:disable:next identifier_name
        guard case .try_(let body, let catch_) = ast else { return [] }
        do {
            return try evalNode(value, body, ctx)
        } catch let err as JqBreak {
            throw err
        } catch let err as JqThrown {
            if let catchExpr = catch_ {
                return try evalNode(err.value, catchExpr, ctx)
            }
            return []
        } catch let err as JqError {
            if let catchExpr = catch_ {
                return try evalNode(.string(err.message), catchExpr, ctx)
            }
            return []
        } catch {
            if let catchExpr = catch_ {
                return try evalNode(.string(String(describing: error)), catchExpr, ctx)
            }
            return []
        }
    }

    static func evalOptional(_ value: JqValue, expr: JqAST, ctx: JqContext) throws -> [JqValue] {
        do {
            return try evalNode(value, expr, ctx)
        } catch _ as JqBreak {
            // Rethrow break so label-flow unwinds reach their target.
            throw JqBreak(label: "")
        } catch {
            return []
        }
    }

    static func evalVarBind(_ value: JqValue, ast: JqAST, ctx: JqContext) throws -> [JqValue] {
        guard case .varBind(let pat, let alts, let valueAST, let body) = ast else { return [] }
        let values = try evalNode(value, valueAST, ctx)
        var out: [JqValue] = []
        for item in values {
            let patternsToTry = [pat] + alts
            var bound: JqContext?
            for pattern in patternsToTry {
                if let nctx = bindPattern(ctx, pattern, item) {
                    bound = nctx
                    break
                }
            }
            guard let nctx = bound else { continue }
            out.append(contentsOf: try evalNode(value, body, nctx))
        }
        return out
    }

    static func evalVarRef(name: String, ctx: JqContext) throws -> [JqValue] {
        if name == "$ENV" || name == "$__loc__" {
            if name == "$ENV" {
                var obj = JqObject()
                for (key, envVal) in ctx.env { obj[key] = .string(envVal) }
                return [.object(obj)]
            }
            var obj = JqObject()
            obj["file"] = .string("<top-level>")
            obj["line"] = .number(1)
            return [.object(obj)]
        }
        if let bound = ctx.vars[name] { return [bound] }
        // jq throws "$name is not defined" — but in many places callers
        // catch via try/?, so prefer error.
        throw JqError("$\(String(name.dropFirst())) is not defined")
    }

    static func evalReduce(_ value: JqValue, ast: JqAST, ctx: JqContext) throws -> [JqValue] {
        // AST label `init_` mirrors a Swift keyword; required for jq reduce init.
        // swiftlint:disable:next identifier_name
        guard case .reduce(let expr, let pat, let init_, let update) = ast else { return [] }
        let items = try evalNode(value, expr, ctx)
        var acc = (try evalNode(value, init_, ctx)).first ?? .null
        for item in items {
            guard let nctx = bindPattern(ctx, pat, item) else { continue }
            let next = try evalNode(acc, update, nctx)
            acc = next.first ?? .null
        }
        return [acc]
    }

    static func evalForeach(_ value: JqValue, ast: JqAST, ctx: JqContext) throws -> [JqValue] {
        // AST label `init_` mirrors a Swift keyword; required for jq foreach init.
        // swiftlint:disable:next identifier_name
        guard case .foreach(let expr, let pat, let init_, let update, let extract) = ast else { return [] }
        let items = try evalNode(value, expr, ctx)
        var state = (try evalNode(value, init_, ctx)).first ?? .null
        var out: [JqValue] = []
        for item in items {
            guard let nctx = bindPattern(ctx, pat, item) else { continue }
            let next = try evalNode(state, update, nctx)
            state = next.first ?? .null
            if let extractExpr = extract {
                out.append(contentsOf: try evalNode(state, extractExpr, nctx))
            } else {
                out.append(state)
            }
        }
        return out
    }

    static func evalLabel(_ value: JqValue,
                          name: String,
                          body: JqAST,
                          ctx: JqContext) throws -> [JqValue] {
        ctx.labels.insert(name)
        defer { ctx.labels.remove(name) }
        do {
            return try evalNode(value, body, ctx)
        } catch let brk as JqBreak where brk.label == name {
            return brk.partial
        }
    }

    static func evalDef(_ value: JqValue, ast: JqAST, ctx: JqContext) throws -> [JqValue] {
        guard case .def(let name, let params, let funcBody, let body) = ast else { return [] }
        let key = "\(name)/\(params.count)"
        let funcDef = JqFunc(params: params, body: funcBody, closure: ctx.funcs)
        let saved = ctx.funcs
        ctx.funcs[key] = funcDef
        defer { ctx.funcs = saved }
        return try evalNode(value, body, ctx)
    }
}
