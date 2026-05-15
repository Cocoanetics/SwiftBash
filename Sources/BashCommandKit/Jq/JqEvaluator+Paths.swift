import Foundation

// Update operations and path-collection routines used by `=`, `|=`,
// `path/1`, and `del/1`.

extension JqEvaluator {

    // The update operator covers eight distinct assignment forms, each
    // with its own value-evaluation context. The switch is intrinsically
    // wide; splitting per-case would not improve readability.
    // swiftlint:disable:next cyclomatic_complexity
    static func applyUpdate(_ root: JqValue,
                            _ pathExpr: JqAST,
                            _ updateOp: JqUpdateOp,
                            _ valueExpr: JqAST,
                            _ ctx: JqContext) throws -> JqValue {
        var paths: [[JqValue]] = []
        try collectPaths(root, pathExpr, ctx, [], &paths)
        var result = root
        // Sort longest first so child updates don't get clobbered when
        // we later set parent paths.
        let sorted = paths.sorted { $0.count > $1.count }
        for path in sorted {
            let current = JqPathOps.getPath(result, path)
            let newVal: JqValue
            switch updateOp {
            case .assign:
                newVal = try firstOrNull(root, valueExpr, ctx)
            case .pipeAssign:
                newVal = try firstOrNull(current, valueExpr, ctx)
            case .addAssign:
                newVal = try applyBinary(.add, current, try firstOrNull(root, valueExpr, ctx))
            case .subAssign:
                newVal = try applyBinary(.sub, current, try firstOrNull(root, valueExpr, ctx))
            case .mulAssign:
                newVal = try applyBinary(.mul, current, try firstOrNull(root, valueExpr, ctx))
            case .divAssign:
                newVal = try applyBinary(.div, current, try firstOrNull(root, valueExpr, ctx))
            case .modAssign:
                newVal = try applyBinary(.mod, current, try firstOrNull(root, valueExpr, ctx))
            case .altAssign:
                if case .null = current {
                    newVal = try firstOrNull(root, valueExpr, ctx)
                } else if case .bool(false) = current {
                    newVal = try firstOrNull(root, valueExpr, ctx)
                } else {
                    newVal = current
                }
            }
            result = try JqPathOps.setPath(result, path, newVal)
        }
        return result
    }

    private static func firstOrNull(_ root: JqValue,
                                    _ valueExpr: JqAST,
                                    _ ctx: JqContext) throws -> JqValue {
        let vals = try evalNode(root, valueExpr, ctx)
        return vals.first ?? .null
    }

    static func extractPath(_ ast: JqAST) -> [JqValue]? {
        switch ast {
        case .identity: return []
        case .field(let name, let base):
            var path = base.flatMap(extractPath) ?? []
            path.append(.string(name))
            return base == nil || extractPath(base!) != nil ? path : nil
        case .index(let idx, let base):
            if case .literal(let item) = idx {
                var path = base.flatMap(extractPath) ?? []
                path.append(item)
                return base == nil || extractPath(base!) != nil ? path : nil
            }
            return nil
        case .pipe(let left, let right):
            guard let leftPath = extractPath(left), let rightPath = extractPath(right) else {
                return nil
            }
            return leftPath + rightPath
        default:
            return nil
        }
    }

    // Collect all concrete paths produced by evaluating `expr` against
    // `value`. Used by `path/1`, `del/1`, update operators.
    // swiftlint:disable:next cyclomatic_complexity
    static func collectPaths(_ value: JqValue,
                             _ expr: JqAST,
                             _ ctx: JqContext,
                             _ basePath: [JqValue],
                             _ paths: inout [[JqValue]]) throws {
        let frame = PathFrame(value: value, ctx: ctx, basePath: basePath)
        switch expr {
        case .identity:
            paths.append(basePath)
        case .recurse:
            collectRecursePaths(frame, paths: &paths)
        case .field(let name, let base):
            try collectFieldPaths(frame, name: name, base: base, paths: &paths)
        case .index(let idx, let base):
            try collectIndexPaths(frame, idx: idx, base: base, paths: &paths)
        case .iterate(let base):
            try collectIteratePaths(frame, base: base, paths: &paths)
        case .slice(let startAST, let endAST, let base):
            try collectSlicePaths(frame, startAST: startAST, endAST: endAST, base: base,
                                  paths: &paths)
        case .pipe(let left, let right):
            try collectPipePaths(frame, left: left, right: right, paths: &paths)
        case .comma(let left, let right):
            try collectPaths(value, left, ctx, basePath, &paths)
            try collectPaths(value, right, ctx, basePath, &paths)
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
        case .cond:
            try collectCondPaths(frame, ast: expr, paths: &paths)
        default:
            // Fallback: just evaluate; if it produces values, treat as
            // identity path (best-effort for unsupported AST shapes).
            let result = try evalNode(value, expr, ctx)
            if !result.isEmpty { paths.append(basePath) }
        }
    }

    /// Stable shared state for path-collection helpers. Bundles the
    /// receiver value, evaluator context, and current base path so per-
    /// AST helpers don't blow the parameter-count budget.
    fileprivate struct PathFrame {
        let value: JqValue
        let ctx: JqContext
        let basePath: [JqValue]
    }

    private static func collectRecursePaths(_ frame: PathFrame, paths: inout [[JqValue]]) {
        func walk(_ item: JqValue, _ path: [JqValue]) {
            paths.append(path)
            switch item {
            case .array(let arr):
                for (index, sub) in arr.enumerated() {
                    walk(sub, path + [.number(Double(index))])
                }
            case .object(let obj):
                for (key, sub) in obj {
                    walk(sub, path + [.string(key)])
                }
            default: break
            }
        }
        walk(frame.value, frame.basePath)
    }

    private static func collectFieldPaths(_ frame: PathFrame,
                                          name: String,
                                          base: JqAST?,
                                          paths: inout [[JqValue]]) throws {
        if let baseExpr = base {
            var basePaths: [[JqValue]] = []
            try collectPaths(frame.value, baseExpr, frame.ctx, frame.basePath, &basePaths)
            for path in basePaths {
                paths.append(path + [.string(name)])
            }
        } else {
            paths.append(frame.basePath + [.string(name)])
        }
    }

    private static func collectIndexPaths(_ frame: PathFrame,
                                          idx: JqAST,
                                          base: JqAST?,
                                          paths: inout [[JqValue]]) throws {
        let bases = try resolveBasePaths(frame, base: base)
        for path in bases {
            let target = JqPathOps.getPath(frame.value, path.dropFirst(frame.basePath.count).map { $0 })
            let idxs = try evalNode(target, idx, frame.ctx)
            for idxVal in idxs {
                paths.append(path + [idxVal])
            }
        }
    }

    private static func collectIteratePaths(_ frame: PathFrame,
                                            base: JqAST?,
                                            paths: inout [[JqValue]]) throws {
        let bases = try resolveBasePaths(frame, base: base)
        for path in bases {
            let relative = Array(path.dropFirst(frame.basePath.count))
            let target = JqPathOps.getPath(frame.value, relative)
            switch target {
            case .array(let arr):
                for index in 0..<arr.count {
                    paths.append(path + [.number(Double(index))])
                }
            case .object(let obj):
                for key in obj.keys {
                    paths.append(path + [.string(key)])
                }
            default: break
            }
        }
    }

    private static func collectSlicePaths(_ frame: PathFrame,
                                          startAST: JqAST?,
                                          endAST: JqAST?,
                                          base: JqAST?,
                                          paths: inout [[JqValue]]) throws {
        let bases = try resolveBasePaths(frame, base: base)
        for path in bases {
            let relative = Array(path.dropFirst(frame.basePath.count))
            let target = JqPathOps.getPath(frame.value, relative)
            guard case .array(let arr) = target else { continue }
            let len = arr.count
            let starts: [JqValue] = try startAST.map { try evalNode(frame.value, $0, frame.ctx) }
                ?? [.number(0)]
            let ends: [JqValue] = try endAST.map { try evalNode(frame.value, $0, frame.ctx) }
                ?? [.number(Double(len))]
            for startVal in starts {
                for endVal in ends {
                    var sNum = 0.0
                    if case .number(let num) = startVal { sNum = num }
                    var eNum = Double(len)
                    if case .number(let num) = endVal { eNum = num }
                    var slice = JqObject()
                    slice["start"] = .number(sNum)
                    slice["end"] = .number(eNum)
                    paths.append(path + [.object(slice)])
                }
            }
        }
    }

    private static func collectPipePaths(_ frame: PathFrame,
                                         left: JqAST,
                                         right: JqAST,
                                         paths: inout [[JqValue]]) throws {
        var leftPaths: [[JqValue]] = []
        try collectPaths(frame.value, left, frame.ctx, frame.basePath, &leftPaths)
        for path in leftPaths {
            let target = JqPathOps.getPath(frame.value,
                                            Array(path.dropFirst(frame.basePath.count)))
            try collectPaths(target, right, frame.ctx, path, &paths)
        }
    }

    private static func collectCondPaths(_ frame: PathFrame,
                                         ast: JqAST,
                                         paths: inout [[JqValue]]) throws {
        // AST label `else_` mirrors a Swift keyword; rename would break public AST.
        // swiftlint:disable:next identifier_name
        guard case .cond(let cond, let thenB, let elifs, let else_) = ast else { return }
        let conds = try evalNode(frame.value, cond, frame.ctx)
        for condVal in conds {
            if condVal.isTruthy {
                try collectPaths(frame.value, thenB, frame.ctx, frame.basePath, &paths)
                continue
            }
            var matched = false
            for (elifCond, elifThen) in elifs {
                let elifVals = try evalNode(frame.value, elifCond, frame.ctx)
                if elifVals.contains(where: { $0.isTruthy }) {
                    try collectPaths(frame.value, elifThen, frame.ctx, frame.basePath, &paths)
                    matched = true
                    break
                }
            }
            if !matched, let elseExpr = else_ {
                try collectPaths(frame.value, elseExpr, frame.ctx, frame.basePath, &paths)
            } else if !matched {
                paths.append(frame.basePath)
            }
        }
    }

    private static func resolveBasePaths(_ frame: PathFrame, base: JqAST?) throws -> [[JqValue]] {
        guard let baseExpr = base else { return [frame.basePath] }
        var basePaths: [[JqValue]] = []
        try collectPaths(frame.value, baseExpr, frame.ctx, frame.basePath, &basePaths)
        return basePaths
    }
}
