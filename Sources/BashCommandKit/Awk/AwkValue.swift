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
        case .number(let num): return num != 0
        case .string(let str):
            if str.isEmpty { return false }
            if str == "0" { return false }
            return true
        }
    }

    /// Numeric coercion: strings parse as `Double` (lossy); failure
    /// yields `0`, matching POSIX. NaN is preserved.
    public var asNumber: Double {
        switch self {
        case .number(let num): return num
        case .string(let str):
            return AwkValue.parseLeadingNumber(str)
        }
    }

    /// String coercion. Numbers stringify with awk-style trimming:
    /// integers print without `.0`. Non-integers use Swift's default
    /// shortest round-trip.
    public var asString: String {
        switch self {
        case .string(let str): return str
        case .number(let num): return AwkValue.formatNumber(num)
        }
    }

    /// "Looks like a number" — leading whitespace, optional sign, the
    /// usual decimal/exponent forms. Used by comparison to decide
    /// between numeric and lexical ordering.
    public var looksLikeNumber: Bool {
        switch self {
        case .number: return true
        case .string(let str):
            let trimmed = str.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            return Double(trimmed) != nil
        }
    }

    public static func formatNumber(_ num: Double) -> String {
        if num.isNaN { return "nan" }
        if num.isInfinite { return num > 0 ? "inf" : "-inf" }
        if num == num.rounded() && abs(num) < 1e16 {
            return String(Int64(num))
        }
        // Mimic AWK's default %.6g for non-integer numbers.
        return AwkPrintf.format("%.6g", values: [.number(num)])
    }

    /// Parse a leading prefix as a number (matching `strtod`):
    /// leading whitespace, optional sign, digits / dot / exponent.
    /// Returns 0 when no digits are present.
    static func parseLeadingNumber(_ str: String) -> Double {
        let chars = Array(str)
        var idx = 0
        while idx < chars.count, chars[idx] == " " || chars[idx] == "\t" { idx += 1 }
        let start = idx
        if idx < chars.count, chars[idx] == "+" || chars[idx] == "-" { idx += 1 }
        var sawDigit = false
        while idx < chars.count, chars[idx].isASCII, chars[idx].isNumber {
            idx += 1; sawDigit = true
        }
        if idx < chars.count, chars[idx] == "." {
            idx += 1
            while idx < chars.count, chars[idx].isASCII, chars[idx].isNumber {
                idx += 1; sawDigit = true
            }
        }
        if sawDigit, idx < chars.count, chars[idx] == "e" || chars[idx] == "E" {
            var expIdx = idx + 1
            if expIdx < chars.count, chars[expIdx] == "+" || chars[expIdx] == "-" {
                expIdx += 1
            }
            var expDigit = false
            while expIdx < chars.count, chars[expIdx].isASCII, chars[expIdx].isNumber {
                expIdx += 1; expDigit = true
            }
            if expDigit { idx = expIdx }
        }
        if !sawDigit { return 0 }
        let prefix = String(chars[start..<idx])
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
