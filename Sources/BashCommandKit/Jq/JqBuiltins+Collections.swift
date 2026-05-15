import Foundation

// Object jq builtins, plus the `toStream` / `fromStream` / `flatten`
// helpers they share. Split from `JqBuiltins.swift` to keep that file
// under SwiftLint's file-length limit. Array builtins live in
// `JqBuiltins+Array.swift`.
extension JqBuiltins {

    // MARK: - Object group

    // Object switch: branch per jq object builtin (has/keys/with_entries/...).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func objectBuiltin(_ value: JqValue, _ name: String,
                              _ args: [JqAST], _ ctx: JqContext) throws -> [JqValue]? {
        switch name {
        case "keys":
            switch value {
            case .array(let arr): return [.array((0..<arr.count).map { .number(Double($0)) })]
            case .object(let obj): return [.array(obj.keys.sorted().map { .string($0) })]
            default: return [.null]
            }
        case "keys_unsorted":
            switch value {
            case .array(let arr): return [.array((0..<arr.count).map { .number(Double($0)) })]
            case .object(let obj): return [.array(obj.keys.map { .string($0) })]
            default: return [.null]
            }
        case "length":
            switch value {
            case .null: return [.number(0)]
            case .string(let str): return [.number(Double(str.count))]
            case .array(let arr): return [.number(Double(arr.count))]
            case .object(let obj): return [.number(Double(obj.count))]
            case .number(let num): return [.number(abs(num))]
            case .bool: throw JqError("boolean has no length")
            }
        case "utf8bytelength":
            guard case .string(let str) = value else {
                throw JqError("\(value.typeName) has no utf8 byte length")
            }
            return [.number(Double(str.utf8.count))]
        case "to_entries":
            guard case .object(let obj) = value else { return [.null] }
            return [.array(obj.map { (key, val) in
                .object(JqObject([("key", .string(key)), ("value", val)]))
            })]
        case "from_entries":
            guard case .array(let arr) = value else { return [.null] }
            var obj = JqObject()
            for item in arr {
                guard case .object(let entry) = item else { continue }
                let key = entry["key"] ?? entry["Key"] ?? entry["name"] ?? entry["Name"] ?? entry["k"]
                let val = entry["value"] ?? entry["Value"] ?? entry["v"] ?? .null
                if let key {
                    let keyStr: String
                    switch key {
                    case .string(let str): keyStr = str
                    case .number(let num): keyStr = JqValue.formatDouble(num)
                    default: keyStr = JqFormatter.compact(key)
                    }
                    obj[keyStr] = val
                }
            }
            return [.object(obj)]
        case "with_entries":
            guard !args.isEmpty else { return [value] }
            guard case .object(let inner) = value else { return [.null] }
            var entries: [JqValue] = []
            for (key, val) in inner {
                entries.append(.object(JqObject([("key", .string(key)), ("value", val)])))
            }
            var mapped: [JqValue] = []
            for entry in entries {
                mapped.append(contentsOf: try JqEvaluator.evalNode(entry, args[0], ctx))
            }
            var obj = JqObject()
            for item in mapped {
                guard case .object(let entry) = item else { continue }
                let key = entry["key"] ?? entry["name"] ?? entry["k"]
                let val = entry["value"] ?? entry["v"] ?? .null
                if let key {
                    let keyStr: String
                    switch key {
                    case .string(let str): keyStr = str
                    case .number(let num): keyStr = JqValue.formatDouble(num)
                    default: keyStr = JqFormatter.compact(key)
                    }
                    obj[keyStr] = val
                }
            }
            return [.object(obj)]
        case "reverse":
            switch value {
            case .array(let arr): return [.array(arr.reversed())]
            case .string(let str): return [.string(String(str.reversed()))]
            default: return [.null]
            }
        case "flatten":
            guard case .array(let arr) = value else { return [.null] }
            let depths: [JqValue] = try args.first.map {
                try JqEvaluator.evalNode(value, $0, ctx)
            } ?? [.number(.infinity)]
            return depths.map { depthValue -> JqValue in
                var depth = Int.max
                if case .number(let num) = depthValue {
                    if num.isInfinite {
                        depth = Int.max
                    } else if num < 0 {
                        return .null
                    } else {
                        depth = Int(num)
                    }
                }
                return .array(flatten(arr, depth: depth))
            }
        case "unique":
            guard case .array(let arr) = value else { return [.null] }
            var seen: [String] = []
            var out: [JqValue] = []
            for item in arr {
                let keyStr = JqFormatter.compact(item, sortKeys: true)
                if !seen.contains(keyStr) {
                    seen.append(keyStr)
                    out.append(item)
                }
            }
            out.sort { JqValue.jqCompare($0, $1) < 0 }
            return [.array(out)]
        case "tojson":
            return [.string(JqFormatter.compact(value))]
        case "fromjson":
            guard case .string(let str) = value else { return [value] }
            return [try JqJSON.parse(str)]
        case "tostring":
            if case .string = value { return [value] }
            return [.string(JqFormatter.compact(value))]
        case "tonumber":
            switch value {
            case .number: return [value]
            case .string(let str):
                guard let num = Double(str.trimmingCharacters(in: .whitespaces)) else {
                    throw JqError("\(JqFormatter.compact(value)) cannot be parsed as a number")
                }
                return [.number(num)]
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
            return [.array(toStream(value, prefix: []))].flatMap { (any: JqValue) -> [JqValue] in
                if case .array(let arr) = any { return arr }
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

    static func toStream(_ value: JqValue, prefix: [JqValue]) -> [JqValue] {
        var out: [JqValue] = []
        switch value {
        case .array(let arr):
            if arr.isEmpty {
                out.append(.array([.array(prefix), .array([])]))
            } else {
                for (idx, item) in arr.enumerated() {
                    out.append(contentsOf: toStream(item, prefix: prefix + [.number(Double(idx))]))
                }
                out.append(.array([.array(prefix + [.number(Double(arr.count - 1))])]))
            }
        case .object(let obj):
            if obj.isEmpty {
                out.append(.array([.array(prefix), .object(JqObject())]))
            } else {
                let keys = Array(obj.keys)
                for key in keys {
                    out.append(contentsOf: toStream(obj[key]!, prefix: prefix + [.string(key)]))
                }
                if let lastKey = keys.last {
                    out.append(.array([.array(prefix + [.string(lastKey)])]))
                }
            }
        default:
            out.append(.array([.array(prefix), value]))
        }
        return out
    }

    static func fromStream(_ items: [JqValue]) -> [JqValue] {
        var result: JqValue = .null
        var produced: [JqValue] = []
        for item in items {
            guard case .array(let arr) = item else { continue }
            if arr.count == 1 {
                if case .array(let path) = arr[0], path.isEmpty {
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
                if case .number = path[0] { result = .array([]) } else { result = .object(JqObject()) }
            }
            result = (try? JqPathOps.setPath(result, path, val)) ?? result
        }
        if case .null = result {} else { produced.append(result) }
        return produced
    }
}
