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
        let value = try parser.parseValue()
        parser.skipWhitespace()
        if !parser.atEnd {
            throw JqError("jq: parse error: garbage after JSON value")
        }
        return value
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
                let char = chars[pos]
                if char == " " || char == "\t" || char == "\n" || char == "\r" {
                    pos += 1
                } else {
                    break
                }
            }
        }

        mutating func peek() -> Character? {
            pos < chars.count ? chars[pos] : nil
        }

        mutating func parseValue() throws -> JqValue {
            skipWhitespace()
            guard let char = peek() else {
                throw JqError("jq: parse error: unexpected end of input")
            }
            switch char {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return try parseString()
            case "t": return try parseLiteral("true", value: .bool(true))
            case "f": return try parseLiteral("false", value: .bool(false))
            case "n": return try parseLiteral("null", value: .null)
            case "-", "0"..."9": return try parseNumber()
            default:
                throw JqError("jq: parse error: unexpected character '\(char)'")
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
                guard case .string(let keyStr) = key else {
                    throw JqError("jq: parse error: invalid key")
                }
                skipWhitespace()
                guard peek() == ":" else {
                    throw JqError("jq: parse error: expected ':'")
                }
                pos += 1
                let value = try parseValue()
                obj[keyStr] = value
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
                let value = try parseValue()
                arr.append(value)
                skipWhitespace()
                if peek() == "," { pos += 1; continue }
                if peek() == "]" { pos += 1; return .array(arr) }
                throw JqError("jq: parse error: expected ',' or ']'")
            }
        }

        // JSON string parser: 8 simple escapes + \u + surrogate pair
        // logic, all sharing the `chars`/`pos` cursor. The body is one
        // cohesive scanner; per-escape helpers would force shared state
        // through inout parameters.
        // swiftlint:disable:next cyclomatic_complexity function_body_length
        mutating func parseString() throws -> JqValue {
            pos += 1
            var str = ""
            while pos < chars.count {
                let char = chars[pos]
                if char == "\"" { pos += 1; return .string(str) }
                if char == "\\" {
                    pos += 1
                    if pos >= chars.count { break }
                    let esc = chars[pos]
                    switch esc {
                    case "\"": str.append("\""); pos += 1
                    case "\\": str.append("\\"); pos += 1
                    case "/": str.append("/"); pos += 1
                    case "b": str.append("\u{08}"); pos += 1
                    case "f": str.append("\u{0C}"); pos += 1
                    case "n": str.append("\n"); pos += 1
                    case "r": str.append("\r"); pos += 1
                    case "t": str.append("\t"); pos += 1
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
                                if let scalar = Unicode.Scalar(combined) {
                                    str.append(Character(scalar))
                                }
                                continue
                            }
                        }
                        if let scalar = Unicode.Scalar(code) {
                            str.append(Character(scalar))
                        }
                    default:
                        throw JqError("jq: parse error: bad escape \\\(esc)")
                    }
                } else {
                    str.append(char)
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
            let str = String(chars[start..<pos])
            guard let num = Double(str) else {
                throw JqError("jq: parse error: invalid number")
            }
            return .number(num)
        }

        mutating func parseLiteral(_ keyword: String, value: JqValue) throws -> JqValue {
            for char in keyword {
                if pos >= chars.count || chars[pos] != char {
                    throw JqError("jq: parse error: expected '\(keyword)'")
                }
                pos += 1
            }
            return value
        }
    }
}
