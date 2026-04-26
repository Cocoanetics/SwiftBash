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
        for (k, v) in pairs { self[k] = v }
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
        var i = 0
        return AnyIterator {
            guard i < self.keys.count else { return nil }
            let k = self.keys[i]
            i += 1
            return (k, self.storage[k]!)
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
    /// jq's heterogeneous deep-comparison: orders by type first, then by
    /// value within type. Used by `sort`, `<`, `>`, `min`, `max`.
    public static func jqCompare(_ a: JqValue, _ b: JqValue) -> Int {
        let ta = a.typeOrder, tb = b.typeOrder
        if ta != tb { return ta < tb ? -1 : 1 }
        switch (a, b) {
        case (.null, .null): return 0
        case (.bool(let x), .bool(let y)):
            return x == y ? 0 : (!x && y ? -1 : 1)
        case (.number(let x), .number(let y)):
            // NaN handling: jq sorts NaN as if equal to itself
            if x.isNaN && y.isNaN { return 0 }
            if x.isNaN { return -1 }
            if y.isNaN { return 1 }
            return x < y ? -1 : (x > y ? 1 : 0)
        case (.string(let x), .string(let y)):
            return x < y ? -1 : (x > y ? 1 : 0)
        case (.array(let xs), .array(let ys)):
            for i in 0..<min(xs.count, ys.count) {
                let c = jqCompare(xs[i], ys[i])
                if c != 0 { return c }
            }
            return xs.count == ys.count ? 0 : (xs.count < ys.count ? -1 : 1)
        case (.object(let xo), .object(let yo)):
            let xk = xo.keys.sorted()
            let yk = yo.keys.sorted()
            for i in 0..<min(xk.count, yk.count) {
                if xk[i] != yk[i] {
                    return xk[i] < yk[i] ? -1 : 1
                }
            }
            if xk.count != yk.count {
                return xk.count < yk.count ? -1 : 1
            }
            for k in xk {
                let c = jqCompare(xo[k] ?? .null, yo[k] ?? .null)
                if c != 0 { return c }
            }
            return 0
        default:
            return 0
        }
    }

    /// jq's deep equality. Distinct from Swift `==` only for objects:
    /// key order doesn't matter for equality.
    public static func jqEqual(_ a: JqValue, _ b: JqValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)):
            if x.isNaN && y.isNaN { return true }
            return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let xs), .array(let ys)):
            guard xs.count == ys.count else { return false }
            for i in 0..<xs.count where !jqEqual(xs[i], ys[i]) { return false }
            return true
        case (.object(let xo), .object(let yo)):
            guard xo.count == yo.count else { return false }
            for k in xo.keys {
                guard let yv = yo[k] else { return false }
                if !jqEqual(xo[k]!, yv) { return false }
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
        case (.string(let h), .string(let n)):
            return h.contains(n)
        case (.array(let h), .array(let n)):
            return n.allSatisfy { ni in h.contains { hi in jqContains(hi, ni) } }
        case (.object(let h), .object(let n)):
            for (k, nv) in n {
                guard let hv = h[k] else { return false }
                if !jqContains(hv, nv) { return false }
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
        guard case .number(let n) = self else { return nil }
        if !n.isFinite { return "null" }
        if n == n.rounded() && abs(n) < 1e16 {
            return String(Int64(n))
        }
        return Self.formatDouble(n)
    }

    public static func formatDouble(_ n: Double) -> String {
        if !n.isFinite {
            if n.isNaN { return "null" }
            return n > 0 ? "1.7976931348623157e+308" : "-1.7976931348623157e+308"
        }
        if n == n.rounded() && abs(n) < 1e16 {
            return String(Int64(n))
        }
        // Shortest round-trip representation. Swift's default
        // `String(n)` is shortest-round-trip already.
        return String(n)
    }
}
