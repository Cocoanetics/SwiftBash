import Foundation

/// A streaming JSON parser that handles concatenated JSON values
/// (e.g. `{"a":1}{"b":2}`, NDJSON, or pretty-printed back-to-back
/// objects). Returns each top-level value as a separate ``JqValue``.
public enum JqJSON {

    public static func parseStream(_ source: String) throws -> [JqValue] {
        var parser = Parser(source: source)
        var results: [JqValue] = []
        while true {
            parser.skipWhitespace()
            if parser.atEnd { break }
            results.append(try parser.parseValue())
        }
        return results
    }

    public static func parse(_ source: String) throws -> JqValue {
        var parser = Parser(source: source)
        parser.skipWhitespace()
        let v = try parser.parseValue()
        parser.skipWhitespace()
        if !parser.atEnd {
            throw JqError("jq: parse error: garbage after JSON value")
        }
        return v
    }

    private struct Parser {
        let chars: [Character]
        var pos: Int

        init(source: String) {
            self.chars = Array(source)
            self.pos = 0
        }

        var atEnd: Bool { pos >= chars.count }

        mutating func skipWhitespace() {
            while pos < chars.count {
                let c = chars[pos]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { pos += 1 }
                else { break }
            }
        }

        mutating func peek() -> Character? {
            pos < chars.count ? chars[pos] : nil
        }

        mutating func parseValue() throws -> JqValue {
            skipWhitespace()
            guard let c = peek() else {
                throw JqError("jq: parse error: unexpected end of input")
            }
            switch c {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return try parseString()
            case "t": return try parseLiteral("true", value: .bool(true))
            case "f": return try parseLiteral("false", value: .bool(false))
            case "n": return try parseLiteral("null", value: .null)
            case "-", "0"..."9": return try parseNumber()
            default:
                throw JqError("jq: parse error: unexpected character '\(c)'")
            }
        }

        mutating func parseObject() throws -> JqValue {
            pos += 1
            var obj = JqObject()
            skipWhitespace()
            if peek() == "}" { pos += 1; return .object(obj) }
            while true {
                skipWhitespace()
                guard peek() == "\"" else {
                    throw JqError("jq: parse error: expected string key")
                }
                let key = try parseString()
                guard case .string(let k) = key else {
                    throw JqError("jq: parse error: invalid key")
                }
                skipWhitespace()
                guard peek() == ":" else {
                    throw JqError("jq: parse error: expected ':'")
                }
                pos += 1
                let v = try parseValue()
                obj[k] = v
                skipWhitespace()
                if peek() == "," { pos += 1; continue }
                if peek() == "}" { pos += 1; return .object(obj) }
                throw JqError("jq: parse error: expected ',' or '}'")
            }
        }

        mutating func parseArray() throws -> JqValue {
            pos += 1
            var arr: [JqValue] = []
            skipWhitespace()
            if peek() == "]" { pos += 1; return .array(arr) }
            while true {
                let v = try parseValue()
                arr.append(v)
                skipWhitespace()
                if peek() == "," { pos += 1; continue }
                if peek() == "]" { pos += 1; return .array(arr) }
                throw JqError("jq: parse error: expected ',' or ']'")
            }
        }

        mutating func parseString() throws -> JqValue {
            pos += 1
            var s = ""
            while pos < chars.count {
                let c = chars[pos]
                if c == "\"" { pos += 1; return .string(s) }
                if c == "\\" {
                    pos += 1
                    if pos >= chars.count { break }
                    let e = chars[pos]
                    switch e {
                    case "\"": s.append("\""); pos += 1
                    case "\\": s.append("\\"); pos += 1
                    case "/": s.append("/"); pos += 1
                    case "b": s.append("\u{08}"); pos += 1
                    case "f": s.append("\u{0C}"); pos += 1
                    case "n": s.append("\n"); pos += 1
                    case "r": s.append("\r"); pos += 1
                    case "t": s.append("\t"); pos += 1
                    case "u":
                        pos += 1
                        var hex = ""
                        for _ in 0..<4 {
                            guard pos < chars.count else { break }
                            hex.append(chars[pos]); pos += 1
                        }
                        guard let code = UInt32(hex, radix: 16) else {
                            throw JqError("jq: parse error: bad \\u escape")
                        }
                        // Surrogate pair?
                        if (0xD800...0xDBFF).contains(code),
                           pos + 1 < chars.count, chars[pos] == "\\", chars[pos + 1] == "u" {
                            pos += 2
                            var hex2 = ""
                            for _ in 0..<4 {
                                guard pos < chars.count else { break }
                                hex2.append(chars[pos]); pos += 1
                            }
                            if let code2 = UInt32(hex2, radix: 16),
                               (0xDC00...0xDFFF).contains(code2) {
                                let combined = 0x10000 + ((code - 0xD800) << 10) + (code2 - 0xDC00)
                                if let u = Unicode.Scalar(combined) {
                                    s.append(Character(u))
                                }
                                continue
                            }
                        }
                        if let u = Unicode.Scalar(code) {
                            s.append(Character(u))
                        }
                    default:
                        throw JqError("jq: parse error: bad escape \\\(e)")
                    }
                } else {
                    s.append(c)
                    pos += 1
                }
            }
            throw JqError("jq: parse error: unterminated string")
        }

        mutating func parseNumber() throws -> JqValue {
            let start = pos
            if chars[pos] == "-" { pos += 1 }
            while pos < chars.count, chars[pos].isNumber { pos += 1 }
            if pos < chars.count, chars[pos] == "." {
                pos += 1
                while pos < chars.count, chars[pos].isNumber { pos += 1 }
            }
            if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
                pos += 1
                if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { pos += 1 }
                while pos < chars.count, chars[pos].isNumber { pos += 1 }
            }
            let s = String(chars[start..<pos])
            guard let n = Double(s) else {
                throw JqError("jq: parse error: invalid number")
            }
            return .number(n)
        }

        mutating func parseLiteral(_ keyword: String, value: JqValue) throws -> JqValue {
            for c in keyword {
                if pos >= chars.count || chars[pos] != c {
                    throw JqError("jq: parse error: expected '\(keyword)'")
                }
                pos += 1
            }
            return value
        }
    }
}
