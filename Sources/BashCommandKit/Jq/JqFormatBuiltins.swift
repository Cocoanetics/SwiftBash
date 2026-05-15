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
                case .literal(let str): out += str
                case .interp(let expr):
                    let values = try JqEvaluator.evalNode(value, expr, ctx)
                    for inner in values {
                        // Encode the value through this formatter.
                        let result = try applyOne(name, inner)
                        if case .string(let str) = result { out += str }
                    }
                }
            }
            return [.string(out)]
        }
        return [try applyOne(name, value)]
    }

    // swiftlint:disable:next cyclomatic_complexity - dispatches over 9 named formatters
    static func applyOne(_ name: String, _ value: JqValue) throws -> JqValue {
        switch name {
        case "@base64": return applyBase64(value)
        case "@base64d": return applyBase64Decode(value)
        case "@uri": return applyURI(value)
        case "@urid": return applyURIDecode(value)
        case "@csv": return applyCSV(value)
        case "@tsv": return applyTSV(value)
        case "@json": return .string(JqFormatter.compact(value))
        case "@html": return applyHTML(value)
        case "@sh": return applySh(value)
        case "@text": return applyText(value)
        default:
            throw JqError("Unknown format: \(name)")
        }
    }

    private static func applyBase64(_ value: JqValue) -> JqValue {
        guard case .string(let str) = value else { return .null }
        return .string(Data(str.utf8).base64EncodedString())
    }

    private static func applyBase64Decode(_ value: JqValue) -> JqValue {
        guard case .string(let str) = value else { return .null }
        // Add padding if missing
        var padded = str
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded) else { return .null }
        // swiftlint:disable:next optional_data_string_conversion - base64 decode may yield non-UTF8 binary
        return .string(String(decoding: data, as: UTF8.self))
    }

    private static func applyURI(_ value: JqValue) -> JqValue {
        guard case .string(let str) = value else { return .null }
        // jq's @uri encodes more than encodeURIComponent: !'()*
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            + "0123456789-_.~"
        let allowed = CharacterSet(charactersIn: chars)
        return .string(str.addingPercentEncoding(withAllowedCharacters: allowed) ?? str)
    }

    private static func applyURIDecode(_ value: JqValue) -> JqValue {
        guard case .string(let str) = value else { return .null }
        return .string(str.removingPercentEncoding ?? str)
    }

    private static func applyCSV(_ value: JqValue) -> JqValue {
        guard case .array(let arr) = value else { return .null }
        return .string(arr.map { csvField($0) }.joined(separator: ","))
    }

    private static func applyTSV(_ value: JqValue) -> JqValue {
        guard case .array(let arr) = value else { return .null }
        return .string(arr.map { tsvField($0) }.joined(separator: "\t"))
    }

    private static func applyHTML(_ value: JqValue) -> JqValue {
        guard case .string(let str) = value else { return .null }
        var out = ""
        for char in str {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "'": out += "&#39;"
            case "\"": out += "&quot;"
            default: out.append(char)
            }
        }
        return .string(out)
    }

    private static func applySh(_ value: JqValue) -> JqValue {
        // jq's @sh: array → space-separated quoted args; scalar → quoted.
        switch value {
        case .string(let str): return .string("'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'")
        case .array(let arr):
            let parts = arr.map { inner -> String in
                switch inner {
                case .string(let str): return "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
                case .number(let num): return JqValue.formatDouble(num)
                default: return JqFormatter.compact(inner)
                }
            }
            return .string(parts.joined(separator: " "))
        default:
            return .null
        }
    }

    private static func applyText(_ value: JqValue) -> JqValue {
        switch value {
        case .string: return value
        case .null: return .string("")
        default: return .string(JqFormatter.compact(value))
        }
    }

    static func csvField(_ value: JqValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let num): return JqValue.formatDouble(num)
        case .string(let str):
            if str.contains(",") || str.contains("\"") || str.contains("\n") || str.contains("\r") {
                return "\"" + str.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return str
        default: return JqFormatter.compact(value)
        }
    }

    static func tsvField(_ value: JqValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let num): return JqValue.formatDouble(num)
        case .string(let str):
            return str.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\t", with: "\\t")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")
        default: return JqFormatter.compact(value)
        }
    }
}
