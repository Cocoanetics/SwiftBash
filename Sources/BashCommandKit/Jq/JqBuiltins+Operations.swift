import Foundation

// Control-flow, index, and path jq builtins. Split from
// `JqBuiltins.swift` to keep that file under SwiftLint's file-length
// limit. Tree-walk and SQL builtins live in `JqBuiltins+Navigation.swift`.
extension JqBuiltins {

    // MARK: - Control flow group

    // Control switch: branch per jq control-flow builtin (if/until/while/...).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func controlBuiltin(_ value: JqValue, _ name: String,
                               _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "first":
            if !args.isEmpty {
                let results = try JqEvaluator.evalNode(value, args[0], ctx)
                return results.isEmpty ? [] : [results[0]]
            }
            if case .array(let arr) = value, !arr.isEmpty { return [arr[0]] }
            return [.null]
        case "last":
            if !args.isEmpty {
                let results = try JqEvaluator.evalNode(value, args[0], ctx)
                return results.isEmpty ? [] : [results.last!]
            }
            if case .array(let arr) = value, !arr.isEmpty { return [arr.last!] }
            return [.null]
        case "nth":
            guard !args.isEmpty else { return [.null] }
            let numbers = try JqEvaluator.evalNode(value, args[0], ctx)
            if args.count > 1 {
                let results = try JqEvaluator.evalNode(value, args[1], ctx)
                return numbers.compactMap { nval -> JqValue? in
                    guard case .number(let num) = nval else { return nil }
                    if num < 0 { return nil }
                    let idx = Int(num)
                    return idx < results.count ? results[idx] : nil
                }
            }
            if case .array(let arr) = value {
                return numbers.map { nval -> JqValue in
                    guard case .number(let num) = nval else { return .null }
                    if num < 0 { return .null }
                    let idx = Int(num)
                    return idx < arr.count ? arr[idx] : .null
                }
            }
            return [.null]
        case "range":
            if args.isEmpty { return [] }
            let starts = try JqEvaluator.evalNode(value, args[0], ctx)
            if args.count == 1 {
                var out: [JqValue] = []
                for start in starts {
                    guard case .number(let num) = start else { continue }
                    var cursor = 0.0
                    while cursor < num { out.append(.number(cursor)); cursor += 1 }
                }
                return out
            }
            let ends = try JqEvaluator.evalNode(value, args[1], ctx)
            if args.count == 2 {
                var out: [JqValue] = []
                for start in starts {
                    for end in ends {
                        guard case .number(let startNum) = start,
                              case .number(let endNum) = end else { continue }
                        var cursor = startNum
                        while cursor < endNum { out.append(.number(cursor)); cursor += 1 }
                    }
                }
                return out
            }
            let steps = try JqEvaluator.evalNode(value, args[2], ctx)
            var out: [JqValue] = []
            for start in starts {
                for end in ends {
                    for step in steps {
                        guard case .number(let startNum) = start,
                              case .number(let endNum) = end,
                              case .number(let stepNum) = step, stepNum != 0 else { continue }
                        var cursor = startNum
                        if stepNum > 0 {
                            while cursor < endNum { out.append(.number(cursor)); cursor += stepNum }
                        } else {
                            while cursor > endNum { out.append(.number(cursor)); cursor += stepNum }
                        }
                    }
                }
            }
            return out
        case "limit":
            guard args.count >= 2 else { return [] }
            let numbers = try JqEvaluator.evalNode(value, args[0], ctx)
            var out: [JqValue] = []
            for nval in numbers {
                guard case .number(let num) = nval else { continue }
                if num < 0 { throw JqError("limit doesn't support negative count") }
                if num == 0 { continue }
                let results = try JqEvaluator.evalNode(value, args[1], ctx)
                out.append(contentsOf: results.prefix(Int(num)))
            }
            return out
        case "skip":
            guard args.count >= 2 else { return [] }
            let numbers = try JqEvaluator.evalNode(value, args[0], ctx)
            var out: [JqValue] = []
            for nval in numbers {
                guard case .number(let num) = nval else { continue }
                if num < 0 { throw JqError("skip doesn't support negative count") }
                let results = try JqEvaluator.evalNode(value, args[1], ctx)
                out.append(contentsOf: results.dropFirst(Int(num)))
            }
            return out
        case "isempty":
            guard !args.isEmpty else { return [.bool(true)] }
            let results = (try? JqEvaluator.evalNode(value, args[0], ctx)) ?? []
            return [.bool(results.isEmpty)]
        case "isvalid":
            guard !args.isEmpty else { return [.bool(true)] }
            do {
                let results = try JqEvaluator.evalNode(value, args[0], ctx)
                return [.bool(!results.isEmpty)]
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

    // Index switch: branch per jq index/has/in builtin.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func indexBuiltin(_ value: JqValue, _ name: String,
                             _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "index":
            guard !args.isEmpty else { return [.null] }
            let needles = try JqEvaluator.evalNode(value, args[0], ctx)
            return needles.map { needle -> JqValue in
                switch (value, needle) {
                case (.string(let str), .string(let needleStr)):
                    if needleStr.isEmpty && str.isEmpty { return .null }
                    if let range = str.range(of: needleStr) {
                        return .number(Double(str.distance(from: str.startIndex, to: range.lowerBound)))
                    }
                    return .null
                case (.array(let arr), .array(let nArr)):
                    for idx in 0...max(0, arr.count - nArr.count) {
                        var matched = true
                        for jdx in 0..<nArr.count where
                            idx + jdx >= arr.count || !JqValue.jqEqual(arr[idx + jdx], nArr[jdx]) {
                            matched = false; break
                        }
                        if matched && !nArr.isEmpty { return .number(Double(idx)) }
                    }
                    return .null
                case (.array(let arr), _):
                    if let idx = arr.firstIndex(where: { JqValue.jqEqual($0, needle) }) {
                        return .number(Double(idx))
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
                case (.string(let str), .string(let needleStr)):
                    if let range = str.range(of: needleStr, options: .backwards) {
                        return .number(Double(str.distance(from: str.startIndex, to: range.lowerBound)))
                    }
                    return .null
                case (.array(let arr), _):
                    for idx in stride(from: arr.count - 1, through: 0, by: -1)
                        where JqValue.jqEqual(arr[idx], needle) {
                        return .number(Double(idx))
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
                case (.string(let str), .string(let needleStr)):
                    if needleStr.isEmpty { return .array([]) }
                    var search = str.startIndex
                    while search < str.endIndex,
                          let range = str.range(of: needleStr, range: search..<str.endIndex) {
                        result.append(.number(Double(str.distance(from: str.startIndex,
                                                                   to: range.lowerBound))))
                        search = str.index(after: range.lowerBound)
                    }
                case (.array(let arr), .array(let nArr)):
                    if nArr.isEmpty {
                        for idx in 0...arr.count { result.append(.number(Double(idx))) }
                    } else {
                        for idx in 0...max(0, arr.count - nArr.count) {
                            var matched = true
                            for jdx in 0..<nArr.count where
                                idx + jdx >= arr.count || !JqValue.jqEqual(arr[idx + jdx], nArr[jdx]) {
                                matched = false; break
                            }
                            if matched { result.append(.number(Double(idx))) }
                        }
                    }
                case (.array(let arr), _):
                    for (idx, val) in arr.enumerated() where JqValue.jqEqual(val, needle) {
                        result.append(.number(Double(idx)))
                    }
                default: break
                }
                return .array(result)
            }
        default: return nil
        }
    }

    // MARK: - Path group

    // Path switch: branch per jq path-related builtin (paths/leaf_paths/setpath/...).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func pathBuiltin(_ value: JqValue, _ name: String,
                            _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "getpath":
            guard !args.isEmpty else { return [.null] }
            let paths = try JqEvaluator.evalNode(value, args[0], ctx)
            return paths.map { pathValue -> JqValue in
                guard case .array(let pathArr) = pathValue else { return .null }
                return JqPathOps.getPath(value, pathArr)
            }
        case "setpath":
            guard args.count >= 2 else { return [.null] }
            let paths = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .array(let path) = paths.first ?? .null else { return [.null] }
            let vals = try JqEvaluator.evalNode(value, args[1], ctx)
            return [try JqPathOps.setPath(value, path, vals.first ?? .null)]
        case "delpaths":
            guard !args.isEmpty else { return [value] }
            let lists = try JqEvaluator.evalNode(value, args[0], ctx)
            guard case .array(let paths) = lists.first ?? .array([]) else { return [value] }
            // Sort longest-first so child deletions don't shift parent indices.
            let sorted = paths.compactMap { val -> [JqValue]? in
                if case .array(let arr) = val { return arr } else { return nil }
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
                let val = JqPathOps.getPath(value, path)
                result = try JqPathOps.setPath(result, path, val)
            }
            return [result]
        case "paths":
            var paths: [[JqValue]] = []
            func walk(_ val: JqValue, _ prefix: [JqValue]) {
                switch val {
                case .array(let arr):
                    for (idx, item) in arr.enumerated() {
                        paths.append(prefix + [.number(Double(idx))])
                        walk(item, prefix + [.number(Double(idx))])
                    }
                case .object(let obj):
                    for (key, item) in obj {
                        paths.append(prefix + [.string(key)])
                        walk(item, prefix + [.string(key)])
                    }
                default: break
                }
            }
            walk(value, [])
            if !args.isEmpty {
                let filter = args[0]
                paths = try paths.filter { path in
                    let val = JqPathOps.getPath(value, path)
                    let results = try JqEvaluator.evalNode(val, filter, ctx)
                    return results.contains { $0.isTruthy }
                }
            }
            return paths.map { .array($0) }
        case "leaf_paths":
            var paths: [[JqValue]] = []
            func walk(_ val: JqValue, _ prefix: [JqValue]) {
                switch val {
                case .array(let arr):
                    for (idx, item) in arr.enumerated() {
                        walk(item, prefix + [.number(Double(idx))])
                    }
                case .object(let obj):
                    for (key, item) in obj {
                        walk(item, prefix + [.string(key)])
                    }
                default:
                    paths.append(prefix)
                }
            }
            walk(value, [])
            return paths.map { .array($0) }
        default: return nil
        }
    }
}
