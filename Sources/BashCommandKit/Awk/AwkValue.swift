import Foundation

/// An AWK scalar value. AWK has only two scalar types — string and
/// number — with implicit coercion at every operator. Comparison
/// semantics follow the "looks like a number" rule (POSIX strnum):
/// when both operands parse cleanly as numbers, comparison is
/// numeric; otherwise it's lexical.
public enum AwkValue: Sendable {
    case string(String)
    case number(Double)

    public static let empty: AwkValue = .string("")

    /// AWK truthiness: `0` and `""` are falsy. The bare string `"0"`
    /// is also falsy (it's the canonical zero); `"00"` and `"0.0"`
    /// are truthy because they're not the canonical form.
    public var isTruthy: Bool {
        switch self {
        case .number(let n): return n != 0
        case .string(let s):
            if s.isEmpty { return false }
            if s == "0" { return false }
            return true
        }
    }

    /// Numeric coercion: strings parse as `Double` (lossy); failure
    /// yields `0`, matching POSIX. NaN is preserved.
    public var asNumber: Double {
        switch self {
        case .number(let n): return n
        case .string(let s):
            return AwkValue.parseLeadingNumber(s)
        }
    }

    /// String coercion. Numbers stringify with awk-style trimming:
    /// integers print without `.0`. Non-integers use Swift's default
    /// shortest round-trip.
    public var asString: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return AwkValue.formatNumber(n)
        }
    }

    /// "Looks like a number" — leading whitespace, optional sign, the
    /// usual decimal/exponent forms. Used by comparison to decide
    /// between numeric and lexical ordering.
    public var looksLikeNumber: Bool {
        switch self {
        case .number: return true
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            return Double(t) != nil
        }
    }

    public static func formatNumber(_ n: Double) -> String {
        if n.isNaN { return "nan" }
        if n.isInfinite { return n > 0 ? "inf" : "-inf" }
        if n == n.rounded() && abs(n) < 1e16 {
            return String(Int64(n))
        }
        // Mimic AWK's default %.6g for non-integer numbers.
        return AwkPrintf.format("%.6g", values: [.number(n)])
    }

    /// Parse a leading prefix as a number (matching `strtod`):
    /// leading whitespace, optional sign, digits / dot / exponent.
    /// Returns 0 when no digits are present.
    static func parseLeadingNumber(_ s: String) -> Double {
        let chars = Array(s)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        let start = i
        if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
        var sawDigit = false
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; sawDigit = true }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; sawDigit = true }
        }
        if sawDigit, i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
            var expDigit = false
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1; expDigit = true }
            if expDigit { i = j }
        }
        if !sawDigit { return 0 }
        let prefix = String(chars[start..<i])
        return Double(prefix) ?? 0
    }
}

/// AWK arrays are associative. They live separately from scalars
/// (and you can't reassign an array name to a scalar). We model them
/// with insertion-ordered keys so `for (k in a)` produces a stable
/// (if not specified) order — common AWK idioms rely on consistent
/// iteration during a single run.
public final class AwkArray: @unchecked Sendable {
    public private(set) var keys: [String] = []
    private var storage: [String: AwkValue] = [:]

    public init() {}

    public var count: Int { keys.count }

    public subscript(key: String) -> AwkValue? {
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

    public func remove(_ key: String) {
        if storage.removeValue(forKey: key) != nil {
            keys.removeAll { $0 == key }
        }
    }

    public func clear() {
        keys.removeAll()
        storage.removeAll()
    }
}
