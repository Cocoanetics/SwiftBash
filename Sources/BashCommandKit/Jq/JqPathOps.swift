import Foundation

/// Set a value at the given path within a jq value, creating
/// intermediate arrays/objects as needed. Mirrors jq's `setpath`.
enum JqPathOps {

    static func setPath(_ value: JqValue, _ path: [JqValue], _ newVal: JqValue) throws -> JqValue {
        if path.isEmpty { return newVal }
        let head = path[0]
        let rest = Array(path.dropFirst())
        if case .number(let num) = head {
            if case .object = value {
                throw JqError("Cannot index object with number")
            }
            if num < 0 {
                throw JqError("Out of bounds negative array index")
            }
            let idx = Int(num)
            if idx > 536_870_911 { throw JqError("Array index too large") }
            var arr: [JqValue]
            if case .array(let elements) = value { arr = elements } else { arr = [] }
            while arr.count <= idx { arr.append(.null) }
            arr[idx] = try setPath(arr[idx], rest, newVal)
            return .array(arr)
        }
        if case .string(let key) = head {
            if case .array = value {
                throw JqError("Cannot index array with string")
            }
            var obj: JqObject
            if case .object(let entries) = value { obj = entries } else { obj = JqObject() }
            let current = obj[key] ?? .null
            obj[key] = try setPath(current, rest, newVal)
            return .object(obj)
        }
        return value
    }

    static func deletePath(_ value: JqValue, _ path: [JqValue]) throws -> JqValue {
        if path.isEmpty { return .null }
        if path.count == 1 {
            let key = path[0]
            if case .array(var arr) = value, case .number(let num) = key {
                let idx = Int(num)
                if idx >= 0 && idx < arr.count {
                    arr.remove(at: idx)
                }
                return .array(arr)
            }
            if case .object(var obj) = value, case .string(let keyStr) = key {
                obj.remove(keyStr)
                return .object(obj)
            }
            return value
        }
        let head = path[0]
        let rest = Array(path.dropFirst())
        if case .array(var arr) = value, case .number(let num) = head {
            let idx = Int(num)
            if idx >= 0 && idx < arr.count {
                arr[idx] = try deletePath(arr[idx], rest)
            }
            return .array(arr)
        }
        if case .object(var obj) = value, case .string(let keyStr) = head {
            if let cur = obj[keyStr] {
                obj[keyStr] = try deletePath(cur, rest)
            }
            return .object(obj)
        }
        return value
    }

    /// Get a value at the given path, returning .null when missing.
    static func getPath(_ value: JqValue, _ path: [JqValue]) -> JqValue {
        var current = value
        for key in path {
            switch (current, key) {
            case (.array(let arr), .number(let num)):
                var idx = Int(num)
                if idx < 0 { idx += arr.count }
                if idx >= 0 && idx < arr.count {
                    current = arr[idx]
                } else {
                    return .null
                }
            case (.object(let entries), .string(let keyStr)):
                current = entries[keyStr] ?? .null
            case (.null, _):
                return .null
            default:
                return .null
            }
        }
        return current
    }
}
