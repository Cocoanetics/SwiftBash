import Foundation

/// Implements `@base64`, `@base64d`, `@uri`, `@csv`, `@tsv`, `@json`,
/// `@html`, `@sh`, `@text`. These are special forms in jq's grammar
/// because they may be followed by a templated string:
/// `@csv "\(.a),\(.b)"`. When that interp is supplied, each `\(...)`
/// piece is encoded individually, then joined.
enum JqFormatBuiltins {

    static func evaluate(_ value: JqValue, name: String, interp: [JqStringPart]?, ctx: JqContext) throws -> [JqValue] {
        if let parts = interp {
            // Apply formatter to each interpolated piece, joining with literals.
            var out = ""
            for part in parts {
                switch part {
                case .literal(let s): out += s
                case .interp(let expr):
                    let vs = try JqEvaluator.evalNode(value, expr, ctx)
                    for v in vs {
                        // Encode the value through this formatter.
                        let r = try applyOne(name, v)
                        if case .string(let s) = r { out += s }
                    }
                }
            }
            return [.string(out)]
        }
        return [try applyOne(name, value)]
    }

    static func applyOne(_ name: String, _ value: JqValue) throws -> JqValue {
        switch name {
        case "@base64":
            guard case .string(let s) = value else { return .null }
            return .string(Data(s.utf8).base64EncodedString())
        case "@base64d":
            guard case .string(let s) = value else { return .null }
            // Add padding if missing
            var padded = s
            while padded.count % 4 != 0 { padded += "=" }
            guard let d = Data(base64Encoded: padded) else { return .null }
            return .string(String(decoding: d, as: UTF8.self))
        case "@uri":
            guard case .string(let s) = value else { return .null }
            // jq's @uri encodes more than encodeURIComponent: !'()*
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
            return .string(s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s)
        case "@urid":
            guard case .string(let s) = value else { return .null }
            return .string(s.removingPercentEncoding ?? s)
        case "@csv":
            guard case .array(let arr) = value else { return .null }
            return .string(arr.map { csvField($0) }.joined(separator: ","))
        case "@tsv":
            guard case .array(let arr) = value else { return .null }
            return .string(arr.map { tsvField($0) }.joined(separator: "\t"))
        case "@json":
            return .string(JqFormatter.compact(value))
        case "@html":
            guard case .string(let s) = value else { return .null }
            var out = ""
            for c in s {
                switch c {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "'": out += "&#39;"
                case "\"": out += "&quot;"
                default: out.append(c)
                }
            }
            return .string(out)
        case "@sh":
            // jq's @sh: array → space-separated quoted args; scalar → quoted.
            switch value {
            case .string(let s): return .string("'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'")
            case .array(let arr):
                let parts = arr.map { v -> String in
                    switch v {
                    case .string(let s): return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    case .number(let n): return JqValue.formatDouble(n)
                    default: return JqFormatter.compact(v)
                    }
                }
                return .string(parts.joined(separator: " "))
            default:
                return .null
            }
        case "@text":
            switch value {
            case .string: return value
            case .null: return .string("")
            default: return .string(JqFormatter.compact(value))
            }
        default:
            throw JqError("Unknown format: \(name)")
        }
    }

    static func csvField(_ v: JqValue) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JqValue.formatDouble(n)
        case .string(let s):
            if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        default: return JqFormatter.compact(v)
        }
    }

    static func tsvField(_ v: JqValue) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JqValue.formatDouble(n)
        case .string(let s):
            return s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\t", with: "\\t")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")
        default: return JqFormatter.compact(v)
        }
    }
}
