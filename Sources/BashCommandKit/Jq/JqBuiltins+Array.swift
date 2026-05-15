import Foundation

// Array-group jq builtins, split out of `JqBuiltins+Collections.swift`
// to stay under SwiftLint's file-length limit. Covers sort/group/min/
// max/map/select/has/in/contains/inside and friends.
extension JqBuiltins {

    // Array switch: branch per jq array builtin (map/sort/group_by/...).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func arrayBuiltin(_ value: JqValue, _ name: String,
                             _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "sort":
            guard case .array(let arr) = value else { return [.null] }
            return [.array(arr.sorted { JqValue.jqCompare($0, $1) < 0 })]
        case "sort_by":
            guard case .array(let arr) = value, !args.isEmpty else { return [.null] }
            let keyed = try arr.map { item -> (JqValue, JqValue) in
                let key = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                return (item, key)
            }
            return [.array(keyed.sorted { JqValue.jqCompare($0.1, $1.1) < 0 }.map { $0.0 })]
        case "bsearch":
            guard case .array(let arr) = value, !args.isEmpty else { return [.null] }
            let targets = try JqEvaluator.evalNode(value, args[0], ctx)
            return targets.map { target -> JqValue in
                var low = 0, high = arr.count
                while low < high {
                    let mid = (low + high) / 2
                    if JqValue.jqCompare(arr[mid], target) < 0 { low = mid + 1 } else { high = mid }
                }
                if low < arr.count, JqValue.jqCompare(arr[low], target) == 0 {
                    return .number(Double(low))
                }
                return .number(Double(-low - 1))
            }
        case "unique_by":
            guard case .array(let arr) = value, !args.isEmpty else { return [.null] }
            var seen: [String] = []
            var pairs: [(JqValue, JqValue)] = []
            for item in arr {
                let key = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                let keyStr = JqFormatter.compact(key, sortKeys: true)
                if !seen.contains(keyStr) {
                    seen.append(keyStr)
                    pairs.append((item, key))
                }
            }
            return [.array(pairs.sorted { JqValue.jqCompare($0.1, $1.1) < 0 }.map { $0.0 })]
        case "group_by":
            guard case .array(let arr) = value, !args.isEmpty else { return [.null] }
            var keys: [String] = []
            var groups: [String: [JqValue]] = [:]
            var keyByStr: [String: JqValue] = [:]
            for item in arr {
                let key = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                let keyStr = JqFormatter.compact(key, sortKeys: true)
                if groups[keyStr] == nil {
                    keys.append(keyStr)
                    groups[keyStr] = []
                    keyByStr[keyStr] = key
                }
                groups[keyStr]?.append(item)
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
                let key = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                if JqValue.jqCompare(key, bestKey) > 0 { best = item; bestKey = key }
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
                let key = (try JqEvaluator.evalNode(item, args[0], ctx)).first ?? .null
                if JqValue.jqCompare(key, bestKey) < 0 { best = item; bestKey = key }
            }
            return [best]
        case "add":
            let items: [JqValue]
            if !args.isEmpty {
                items = try JqEvaluator.evalNode(value, args[0], ctx)
            } else if case .array(let arr) = value {
                items = arr
            } else if case .null = value {
                return [.null]
            } else {
                return [.null]
            }
            let nonNull = items.filter { if case .null = $0 { return false } else { return true } }
            if nonNull.isEmpty { return [.null] }
            // Use jq's `+` semantics
            var result = nonNull[0]
            for val in nonNull.dropFirst() {
                result = try JqEvaluator.applyBinary(.add, result, val)
            }
            return [result]
        case "any":
            if args.count >= 2 {
                let gen = try JqEvaluator.evalNode(value, args[0], ctx)
                for val in gen {
                    let conds = try JqEvaluator.evalNode(val, args[1], ctx)
                    if conds.contains(where: { $0.isTruthy }) { return [.bool(true)] }
                }
                return [.bool(false)]
            }
            if args.count == 1 {
                guard case .array(let arr) = value else { return [.bool(false)] }
                for item in arr {
                    let conds = try JqEvaluator.evalNode(item, args[0], ctx)
                    if conds.contains(where: { $0.isTruthy }) { return [.bool(true)] }
                }
                return [.bool(false)]
            }
            guard case .array(let arr) = value else { return [.bool(false)] }
            return [.bool(arr.contains { $0.isTruthy })]
        case "all":
            if args.count >= 2 {
                let gen = try JqEvaluator.evalNode(value, args[0], ctx)
                for val in gen {
                    let conds = try JqEvaluator.evalNode(val, args[1], ctx)
                    if !conds.contains(where: { $0.isTruthy }) { return [.bool(false)] }
                }
                return [.bool(true)]
            }
            if args.count == 1 {
                guard case .array(let arr) = value else { return [.bool(true)] }
                for item in arr {
                    let conds = try JqEvaluator.evalNode(item, args[0], ctx)
                    if !conds.contains(where: { $0.isTruthy }) { return [.bool(false)] }
                }
                return [.bool(true)]
            }
            guard case .array(let arr) = value else { return [.bool(true)] }
            return [.bool(arr.allSatisfy { $0.isTruthy })]
        case "select":
            guard !args.isEmpty else { return [value] }
            let conds = try JqEvaluator.evalNode(value, args[0], ctx)
            return conds.contains(where: { $0.isTruthy }) ? [value] : []
        case "map":
            guard !args.isEmpty, case .array(let arr) = value else { return [.null] }
            var out: [JqValue] = []
            for item in arr {
                out.append(contentsOf: try JqEvaluator.evalNode(item, args[0], ctx))
            }
            return [.array(out)]
        case "map_values":
            guard !args.isEmpty else { return [.null] }
            switch value {
            case .array(let arr):
                var out: [JqValue] = []
                for item in arr {
                    let results = try JqEvaluator.evalNode(item, args[0], ctx)
                    if let first = results.first { out.append(first) }
                }
                return [.array(out)]
            case .object(let obj):
                var out = JqObject()
                for (key, val) in obj {
                    let results = try JqEvaluator.evalNode(val, args[0], ctx)
                    if let first = results.first { out[key] = first }
                }
                return [.object(out)]
            default: return [.null]
            }
        case "has":
            guard !args.isEmpty else { return [.bool(false)] }
            let keys = try JqEvaluator.evalNode(value, args[0], ctx)
            guard let key = keys.first else { return [.bool(false)] }
            switch (value, key) {
            case (.array(let arr), .number(let num)):
                let idx = Int(num)
                return [.bool(idx >= 0 && idx < arr.count)]
            case (.object(let obj), .string(let str)):
                return [.bool(obj.contains(str))]
            default: return [.bool(false)]
            }
        case "in":
            guard !args.isEmpty else { return [.bool(false)] }
            let objs = try JqEvaluator.evalNode(value, args[0], ctx)
            guard let obj = objs.first else { return [.bool(false)] }
            switch (obj, value) {
            case (.array(let arr), .number(let num)):
                let idx = Int(num)
                return [.bool(idx >= 0 && idx < arr.count)]
            case (.object(let inner), .string(let str)):
                return [.bool(inner.contains(str))]
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
}
