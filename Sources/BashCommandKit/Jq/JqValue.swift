import Foundation

/// A jq value: any JSON value, plus support for ordered object keys
/// (to match jq's preservation of insertion order) and IEEE 754 doubles
/// (jq treats every number as a double).
public indirect enum JqValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JqValue])
    case object(JqObject)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var isTruthy: Bool {
        switch self {
        case .null, .bool(false): return false
        default: return true
        }
    }

    /// jq's `type` builtin name.
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// Comparable rank for jq's heterogeneous ordering:
    /// `null < false < true < numbers < strings < arrays < objects`.
    public var typeOrder: Int {
        switch self {
        case .null: return 0
        case .bool(false): return 1
        case .bool(true): return 2
        case .number: return 3
        case .string: return 4
        case .array: return 5
        case .object: return 6
        }
    }
}

/// An ordered JSON object — keys are kept in insertion order, with
/// O(1) lookup. Mirrors how jq preserves source-order for `to_entries`,
/// `keys_unsorted`, and pretty-printed output.
public struct JqObject: Hashable, Sendable {
    public private(set) var keys: [String]
    private var storage: [String: JqValue]

    public init() {
        self.keys = []
        self.storage = [:]
    }

    public init(_ pairs: [(String, JqValue)]) {
        self.keys = []
        self.storage = [:]
        self.keys.reserveCapacity(pairs.count)
        for (key, value) in pairs { self[key] = value }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public subscript(key: String) -> JqValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else {
                if storage.removeValue(forKey: key) != nil {
                    keys.removeAll { $0 == key }
                }
            }
        }
    }

    public func contains(_ key: String) -> Bool { storage[key] != nil }

    public mutating func remove(_ key: String) {
        if storage.removeValue(forKey: key) != nil {
            keys.removeAll { $0 == key }
        }
    }

    public var entries: [(String, JqValue)] {
        keys.map { ($0, storage[$0]!) }
    }
}

extension JqObject: Sequence {
    public func makeIterator() -> AnyIterator<(String, JqValue)> {
        var index = 0
        return AnyIterator {
            guard index < self.keys.count else { return nil }
            let key = self.keys[index]
            index += 1
            return (key, self.storage[key]!)
        }
    }
}

// MARK: - Convenience constructors

extension JqValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JqValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JqValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JqValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JqValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JqValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JqValue...) {
        self = .array(elements)
    }
}

extension JqValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JqValue)...) {
        self = .object(JqObject(elements))
    }
}

// MARK: - Comparison & equality

extension JqValue {
    // jq's heterogeneous deep-comparison: orders by type first, then by
    // value within type. Used by `sort`, `<`, `>`, `min`, `max`.
    // Switch over six JqValue cases × per-case comparison logic
    // (arrays/objects need element-wise traversal); per-case helpers
    // would scatter the type-order dispatch.
    // swiftlint:disable:next cyclomatic_complexity
    public static func jqCompare(_ lhs: JqValue, _ rhs: JqValue) -> Int {
        let lhsOrder = lhs.typeOrder, rhsOrder = rhs.typeOrder
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder ? -1 : 1 }
        switch (lhs, rhs) {
        case (.null, .null): return 0
        case (.bool(let lhsBool), .bool(let rhsBool)):
            return lhsBool == rhsBool ? 0 : (!lhsBool && rhsBool ? -1 : 1)
        case (.number(let lhsNum), .number(let rhsNum)):
            // NaN handling: jq sorts NaN as if equal to itself
            if lhsNum.isNaN && rhsNum.isNaN { return 0 }
            if lhsNum.isNaN { return -1 }
            if rhsNum.isNaN { return 1 }
            return lhsNum < rhsNum ? -1 : (lhsNum > rhsNum ? 1 : 0)
        case (.string(let lhsStr), .string(let rhsStr)):
            return lhsStr < rhsStr ? -1 : (lhsStr > rhsStr ? 1 : 0)
        case (.array(let lhsArr), .array(let rhsArr)):
            for index in 0..<min(lhsArr.count, rhsArr.count) {
                let cmp = jqCompare(lhsArr[index], rhsArr[index])
                if cmp != 0 { return cmp }
            }
            return lhsArr.count == rhsArr.count ? 0 : (lhsArr.count < rhsArr.count ? -1 : 1)
        case (.object(let lhsObj), .object(let rhsObj)):
            let lhsKeys = lhsObj.keys.sorted()
            let rhsKeys = rhsObj.keys.sorted()
            for index in 0..<min(lhsKeys.count, rhsKeys.count)
                where lhsKeys[index] != rhsKeys[index] {
                return lhsKeys[index] < rhsKeys[index] ? -1 : 1
            }
            if lhsKeys.count != rhsKeys.count {
                return lhsKeys.count < rhsKeys.count ? -1 : 1
            }
            for key in lhsKeys {
                let cmp = jqCompare(lhsObj[key] ?? .null, rhsObj[key] ?? .null)
                if cmp != 0 { return cmp }
            }
            return 0
        default:
            return 0
        }
    }

    // jq's deep equality. Distinct from Swift `==` only for objects:
    // key order doesn't matter for equality.
    // Six-case dispatch over the JqValue enum with per-case element-
    // wise traversal — same shape as jqCompare; same rationale.
    // swiftlint:disable:next cyclomatic_complexity
    public static func jqEqual(_ lhs: JqValue, _ rhs: JqValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let lhsBool), .bool(let rhsBool)): return lhsBool == rhsBool
        case (.number(let lhsNum), .number(let rhsNum)):
            if lhsNum.isNaN && rhsNum.isNaN { return true }
            return lhsNum == rhsNum
        case (.string(let lhsStr), .string(let rhsStr)): return lhsStr == rhsStr
        case (.array(let lhsArr), .array(let rhsArr)):
            guard lhsArr.count == rhsArr.count else { return false }
            for index in 0..<lhsArr.count where !jqEqual(lhsArr[index], rhsArr[index]) {
                return false
            }
            return true
        case (.object(let lhsObj), .object(let rhsObj)):
            guard lhsObj.count == rhsObj.count else { return false }
            for key in lhsObj.keys {
                guard let rhsVal = rhsObj[key] else { return false }
                if !jqEqual(lhsObj[key]!, rhsVal) { return false }
            }
            return true
        default:
            return false
        }
    }

    /// jq's "contains" — substring for strings, subset-of-keys with
    /// recursive containment for objects, and "every needle has a
    /// matching haystack item" for arrays.
    public static func jqContains(_ haystack: JqValue, _ needle: JqValue) -> Bool {
        if jqEqual(haystack, needle) { return true }
        switch (haystack, needle) {
        case (.string(let hayStr), .string(let needleStr)):
            return hayStr.contains(needleStr)
        case (.array(let hayArr), .array(let needleArr)):
            return needleArr.allSatisfy { needleItem in
                hayArr.contains { hayItem in jqContains(hayItem, needleItem) }
            }
        case (.object(let hayObj), .object(let needleObj)):
            for (key, needleVal) in needleObj {
                guard let hayVal = hayObj[key] else { return false }
                if !jqContains(hayVal, needleVal) { return false }
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - JSON parsing & emission helpers

extension JqValue {
    /// Number formatted the way jq writes it: integers without `.0`,
    /// `null` for non-finite values (matching jq's output of NaN/inf).
    public var numberJSON: String? {
        guard case .number(let value) = self else { return nil }
        if !value.isFinite { return "null" }
        if value == value.rounded() && abs(value) < 1e16 {
            return String(Int64(value))
        }
        return Self.formatDouble(value)
    }

    public static func formatDouble(_ value: Double) -> String {
        if !value.isFinite {
            if value.isNaN { return "null" }
            return value > 0 ? "1.7976931348623157e+308" : "-1.7976931348623157e+308"
        }
        if value == value.rounded() && abs(value) < 1e16 {
            return String(Int64(value))
        }
        // Shortest round-trip representation. Swift's default
        // `String(value)` is shortest-round-trip already.
        return String(value)
    }
}
