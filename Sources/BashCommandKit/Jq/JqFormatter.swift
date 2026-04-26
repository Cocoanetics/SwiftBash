import Foundation

/// Pretty-prints a ``JqValue`` in jq's canonical format.
public enum JqFormatter {

    public struct Options {
        public var compact: Bool
        public var raw: Bool
        public var sortKeys: Bool
        public var useTab: Bool
        public var indent: Int

        public init(compact: Bool = false, raw: Bool = false,
                    sortKeys: Bool = false, useTab: Bool = false, indent: Int = 2) {
            self.compact = compact
            self.raw = raw
            self.sortKeys = sortKeys
            self.useTab = useTab
            self.indent = indent
        }
    }

    public static func format(_ value: JqValue, options: Options = Options()) -> String {
        if options.raw, case .string(let s) = value { return s }
        if options.compact { return compact(value, sortKeys: options.sortKeys) }
        return pretty(value, options: options, depth: 0)
    }

    public static func compact(_ v: JqValue, sortKeys: Bool = false) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JqValue.formatDouble(n)
        case .string(let s): return jsonString(s)
        case .array(let arr):
            return "[" + arr.map { compact($0, sortKeys: sortKeys) }.joined(separator: ",") + "]"
        case .object(let obj):
            let keys = sortKeys ? obj.keys.sorted() : obj.keys
            let parts = keys.map { k -> String in
                jsonString(k) + ":" + compact(obj[k]!, sortKeys: sortKeys)
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    static func pretty(_ v: JqValue, options: Options, depth: Int) -> String {
        let unit = options.useTab ? "\t" : String(repeating: " ", count: options.indent)
        let indent = String(repeating: unit, count: depth)
        let inner = String(repeating: unit, count: depth + 1)
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JqValue.formatDouble(n)
        case .string(let s): return jsonString(s)
        case .array(let arr):
            if arr.isEmpty { return "[]" }
            let parts = arr.map { inner + pretty($0, options: options, depth: depth + 1) }
            return "[\n" + parts.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let obj):
            if obj.isEmpty { return "{}" }
            let keys = options.sortKeys ? obj.keys.sorted() : obj.keys
            let parts = keys.map { k -> String in
                inner + jsonString(k) + ": " + pretty(obj[k]!, options: options, depth: depth + 1)
            }
            return "{\n" + parts.joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    /// Encode a string as a JSON string literal (RFC 8259), matching
    /// jq's escapes (uses `\u` for control chars, lets U+007F through).
    public static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
