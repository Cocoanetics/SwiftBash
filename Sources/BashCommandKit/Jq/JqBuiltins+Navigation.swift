import Foundation

// Tree-walk and SQL-style jq builtins (walk, recurse, transpose,
// combinations, IN/INDEX, etc.). Split from
// `JqBuiltins+Operations.swift` to keep it under SwiftLint's
// file-length limit.
extension JqBuiltins {

    // MARK: - Navigation group

    // Navigation switch: branch per jq tree-walk builtin (walk/recurse/...).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func navigationBuiltin(_ value: JqValue, _ name: String,
                                  _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "recurse":
            if args.isEmpty {
                var results: [JqValue] = []
                func walk(_ val: JqValue) {
                    results.append(val)
                    switch val {
                    case .array(let arr): for inner in arr { walk(inner) }
                    case .object(let obj): for (_, inner) in obj { walk(inner) }
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
            func walk(_ val: JqValue) throws {
                if depth > maxDepth { return }
                if let cond = condArg {
                    let conds = try JqEvaluator.evalNode(val, cond, ctx)
                    if !conds.contains(where: { $0.isTruthy }) { return }
                }
                results.append(val)
                let next = try JqEvaluator.evalNode(val, args[0], ctx)
                for child in next where !(child.isNull) {
                    depth += 1
                    try walk(child)
                    depth -= 1
                }
            }
            try walk(value)
            return results
        case "recurse_down":
            return try navigationBuiltin(value, "recurse", args, ctx)
        case "walk":
            guard !args.isEmpty else { return [value] }
            func go(_ val: JqValue) throws -> JqValue {
                let transformed: JqValue
                switch val {
                case .array(let arr):
                    var out: [JqValue] = []
                    for item in arr { out.append(try go(item)) }
                    transformed = .array(out)
                case .object(let obj):
                    var out = JqObject()
                    for (key, item) in obj { out[key] = try go(item) }
                    transformed = .object(out)
                default:
                    transformed = val
                }
                let results = try JqEvaluator.evalNode(transformed, args[0], ctx)
                return results.first ?? .null
            }
            return [try go(value)]
        case "transpose":
            guard case .array(let arr) = value else { return [.null] }
            var maxLen = 0
            for row in arr {
                if case .array(let inner) = row, inner.count > maxLen { maxLen = inner.count }
            }
            var out: [JqValue] = []
            for idx in 0..<maxLen {
                var col: [JqValue] = []
                for row in arr {
                    if case .array(let inner) = row, idx < inner.count {
                        col.append(inner[idx])
                    } else {
                        col.append(.null)
                    }
                }
                out.append(.array(col))
            }
            return [.array(out)]
        case "combinations":
            if !args.isEmpty {
                let numbers = try JqEvaluator.evalNode(value, args[0], ctx)
                guard case .number(let num) = numbers.first ?? .null else { return [] }
                guard case .array(let arr) = value else { return [] }
                let count = Int(num)
                if count < 0 { return [] }
                if count == 0 { return [.array([])] }
                var out: [[JqValue]] = []
                func gen(_ cur: [JqValue], _ depth: Int) {
                    if depth == count { out.append(cur); return }
                    for item in arr { gen(cur + [item], depth + 1) }
                }
                gen([], 0)
                return out.map { .array($0) }
            }
            guard case .array(let arr) = value else { return [] }
            for val in arr where !{ if case .array = val { return true } else { return false } }() {
                return []
            }
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
            for idx in stride(from: ctx.currentPath.count - 1, through: 0, by: -1) {
                out.append(JqPathOps.getPath(ctx.root ?? value, Array(ctx.currentPath.prefix(idx))))
            }
            return [.array(out)]
        case "root":
            return [ctx.root ?? value]
        default: return nil
        }
    }

    // MARK: - SQL group

    // SQL switch: branch per jq SQL-style builtin (IN/INDEX/...).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func sqlBuiltin(_ value: JqValue, _ name: String,
                           _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "IN":
            if args.isEmpty { return [.bool(false)] }
            if args.count == 1 {
                let stream = try JqEvaluator.evalNode(value, args[0], ctx)
                return [.bool(stream.contains { JqValue.jqEqual(value, $0) })]
            }
            let firstStream = try JqEvaluator.evalNode(value, args[0], ctx)
            let secondStream = try JqEvaluator.evalNode(value, args[1], ctx)
            for val in firstStream where
                secondStream.contains(where: { JqValue.jqEqual(val, $0) }) {
                return [.bool(true)]
            }
            return [.bool(false)]
        case "INDEX":
            if args.isEmpty { return [.object(JqObject())] }
            if args.count == 1 {
                let stream = try JqEvaluator.evalNode(value, args[0], ctx)
                var obj = JqObject()
                for val in stream {
                    let key: String
                    if case .string(let str) = val { key = str } else { key = JqFormatter.compact(val) }
                    obj[key] = val
                }
                return [.object(obj)]
            }
            if args.count == 2 {
                let stream = try JqEvaluator.evalNode(value, args[0], ctx)
                var obj = JqObject()
                for val in stream {
                    let keys = try JqEvaluator.evalNode(val, args[1], ctx)
                    if let keyVal = keys.first {
                        let str: String
                        if case .string(let val) = keyVal { str = val } else { str = JqFormatter.compact(keyVal) }
                        obj[str] = val
                    }
                }
                return [.object(obj)]
            }
            let stream = try JqEvaluator.evalNode(value, args[0], ctx)
            var obj = JqObject()
            for val in stream {
                let keys = try JqEvaluator.evalNode(val, args[1], ctx)
                let vals = try JqEvaluator.evalNode(val, args[2], ctx)
                if let keyVal = keys.first, let mappedVal = vals.first {
                    let str: String
                    if case .string(let val) = keyVal { str = val } else { str = JqFormatter.compact(keyVal) }
                    obj[str] = mappedVal
                }
            }
            return [.object(obj)]
        default: return nil
        }
    }
}
