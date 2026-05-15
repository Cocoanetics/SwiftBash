import Foundation

extension BcCalculator {

    struct Parser {
        var chars: [Character]
        var pos = 0
        var ctx: Context

        init(input: String, ctx: Context) {
            self.chars = Array(input)
            self.ctx = ctx
        }

        mutating func parseTopLevel() throws -> Double? {
            skipWS()
            // Statement: assignment vs expression.
            // A simple `var = expr` form: detect identifier followed by `=`.
            if let savePos = identAhead() {
                let endName = savePos
                pos = endName
                skipWS()
                if pos < chars.count, chars[pos] == "=", peek(1) != "=" {
                    pos += 1
                    skipWS()
                    let value = try parseExpr()
                    let name = String(chars[0..<endName]).trimmingCharacters(in: .whitespaces)
                    if name == "scale" {
                        ctx.scale = max(0, Int(value))
                    } else {
                        ctx.vars[name] = value
                    }
                    return nil
                }
                pos = 0
            }
            let value = try parseExpr()
            return value
        }

        /// If the input starts with an identifier followed by `=` (not
        /// `==`), return the index just past the identifier; else nil.
        mutating func identAhead() -> Int? {
            let save = pos
            skipWS()
            var idx = pos
            while idx < chars.count, isIdentChar(chars[idx], first: idx == pos) {
                idx += 1
            }
            if idx == pos { pos = save; return nil }
            // Skip whitespace after the name.
            var afterIdx = idx
            while afterIdx < chars.count,
                  chars[afterIdx] == " " || chars[afterIdx] == "\t" {
                afterIdx += 1
            }
            if afterIdx < chars.count, chars[afterIdx] == "=",
               afterIdx + 1 < chars.count, chars[afterIdx + 1] != "=" {
                pos = save
                return idx
            }
            pos = save
            return nil
        }

        // MARK: helpers

        mutating func skipWS() {
            while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
        }
        func peek(_ offset: Int) -> Character? {
            let idx = pos + offset
            return idx < chars.count ? chars[idx] : nil
        }
        func peekStr2() -> String {
            guard pos + 1 < chars.count else { return "" }
            return String(chars[pos]) + String(chars[pos + 1])
        }
        func peekCmpOp() -> String? {
            let two = peekStr2()
            if two == "==" || two == "!=" || two == "<=" || two == ">=" { return two }
            if pos < chars.count {
                if chars[pos] == "<" { return "<" }
                if chars[pos] == ">" { return ">" }
            }
            return nil
        }
        func isIdentChar(_ char: Character, first: Bool) -> Bool {
            if char.isASCII && char.isLetter { return true }
            if char == "_" { return true }
            if !first && char.isASCII && char.isNumber { return true }
            return false
        }
    }
}
