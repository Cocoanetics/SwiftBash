import ArgumentParser
import BashInterpreter
import Foundation

/// `bc [-l] [FILE...]` — arbitrary-precision calculator.
///
/// Reads expressions from stdin (one per line) or FILEs and prints
/// the result of each. Uses Swift `Double` internally (so this isn't
/// truly arbitrary-precision, but matches the practical use case of
/// shell scripts piping `echo "..." | bc`).
///
/// Supported:
/// - operators: `+ - * / % ^` (^ is exponentiation)
/// - comparison: `== != < <= > >=` (return 1 / 0)
/// - logical: `! && ||`
/// - parentheses, unary `-`/`+`
/// - assignment: `var = expr` (variable persists for the session)
/// - functions: `sqrt(x)`, `length(x)` (digit count of integer part),
///   `scale(x)` (return scale value), and the math-lib trig fns
///   `s(x)` `c(x)` `a(x)` `l(x)` `e(x)` (with `-l`).
/// - `scale = N` controls decimals shown for division.
/// - `quit` / `halt` exits.
/// - `# comment` and `/* ... */` are stripped.
public struct BcCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "bc",
        abstract: "Arbitrary-precision calculator language."
    )

    @Flag(name: [.customShort("l"), .customLong("mathlib")],
          help: "Define math library: s c a l e and set scale=20.")
    public var mathlib: Bool = false

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Don't print the GNU bc welcome banner (we never do).")
    public var quiet: Bool = false

    @Argument(help: "Files to evaluate before reading stdin.")
    public var files: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var ctx = Bc.Context()
        if mathlib { ctx.scale = 20 }

        for f in files {
            do {
                let data = try await Shell.current.readDataAtPath(f)
                let text = String(decoding: data, as: UTF8.self)
                if let exit = process(text, ctx: &ctx) {
                    return exit
                }
            } catch {
                Shell.current.stderr("bc: \(f): \(error)\n")
                return .failure
            }
        }
        let stdin = await Shell.current.stdin.readAllString()
        if !stdin.isEmpty {
            if let exit = process(stdin, ctx: &ctx) {
                return exit
            }
        }
        return .success
    }

    /// Process a chunk of bc input. Returns a non-nil status if the
    /// program should exit (e.g., on `quit`).
    private func process(_ text: String, ctx: inout Bc.Context) -> ExitStatus? {
        // Strip /* ... */ comments and # comments.
        var stripped = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "/", text.index(after: i) < text.endIndex,
               text[text.index(after: i)] == "*" {
                // Skip until "*/".
                i = text.index(i, offsetBy: 2)
                while i < text.endIndex {
                    if text[i] == "*", text.index(after: i) < text.endIndex,
                       text[text.index(after: i)] == "/" {
                        i = text.index(i, offsetBy: 2); break
                    }
                    i = text.index(after: i)
                }
                continue
            }
            if c == "#" {
                while i < text.endIndex && text[i] != "\n" { i = text.index(after: i) }
                continue
            }
            stripped.append(c)
            i = text.index(after: i)
        }
        for raw in stripped.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "quit" || line == "halt" { return .success }
            do {
                if let result = try Bc.evalLine(line, ctx: &ctx) {
                    Shell.current.stdout(Bc.format(result, scale: ctx.scale) + "\n")
                }
            } catch let e as Bc.Error {
                Shell.current.stderr("bc: \(e.message)\n")
            } catch {
                Shell.current.stderr("bc: \(error)\n")
            }
        }
        return nil
    }
}

enum Bc {
    struct Context {
        var vars: [String: Double] = [:]
        var scale: Int = 0
    }
    struct Error: Swift.Error { let message: String; init(_ m: String) { self.message = m } }

    /// Evaluate one bc statement. Returns the value to print, or nil
    /// for assignments / scale settings (which are silent).
    static func evalLine(_ line: String, ctx: inout Context) throws -> Double? {
        var p = Parser(input: line, ctx: ctx)
        let r = try p.parseTopLevel()
        ctx = p.ctx
        return r
    }

    /// Format a Double the way bc does: integers without a decimal,
    /// otherwise truncated (not rounded) to `scale` digits.
    static func format(_ v: Double, scale: Int) -> String {
        if v.isNaN { return "nan" }
        if v.isInfinite { return v > 0 ? "inf" : "-inf" }
        if scale == 0 || v == v.rounded(.towardZero) {
            return String(Int64(v.rounded(.towardZero)))
        }
        // Truncate to `scale` decimals.
        let mult = pow(10.0, Double(scale))
        let truncated = (v * mult).rounded(.towardZero) / mult
        var s = String(format: "%.\(scale)f", truncated)
        // Strip trailing zeros, but keep at least one digit after `.`.
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    fileprivate struct Parser {
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
            let v = try parseExpr()
            return v
        }

        /// If the input starts with an identifier followed by `=` (not
        /// `==`), return the index just past the identifier; else nil.
        mutating func identAhead() -> Int? {
            let save = pos
            skipWS()
            var i = pos
            while i < chars.count, isIdentChar(chars[i], first: i == pos) { i += 1 }
            if i == pos { pos = save; return nil }
            // Skip whitespace after the name.
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            if j < chars.count, chars[j] == "=", j + 1 < chars.count, chars[j + 1] != "=" {
                pos = save
                return i
            }
            pos = save
            return nil
        }

        // Precedence climbing — bc grammar:
        //  or > and > comparison > add/sub > mul/div/mod > pow > unary > primary
        mutating func parseExpr() throws -> Double { try parseOr() }
        mutating func parseOr() throws -> Double {
            var l = try parseAnd()
            while peekStr2() == "||" {
                pos += 2; skipWS()
                let r = try parseAnd()
                l = (l != 0 || r != 0) ? 1 : 0
            }
            return l
        }
        mutating func parseAnd() throws -> Double {
            var l = try parseComparison()
            while peekStr2() == "&&" {
                pos += 2; skipWS()
                let r = try parseComparison()
                l = (l != 0 && r != 0) ? 1 : 0
            }
            return l
        }
        mutating func parseComparison() throws -> Double {
            let l = try parseAddSub()
            if let op = peekCmpOp() {
                pos += op.count; skipWS()
                let r = try parseAddSub()
                switch op {
                case "==": return l == r ? 1 : 0
                case "!=": return l != r ? 1 : 0
                case "<=": return l <= r ? 1 : 0
                case ">=": return l >= r ? 1 : 0
                case "<":  return l < r ? 1 : 0
                case ">":  return l > r ? 1 : 0
                default:   return l
                }
            }
            return l
        }
        mutating func parseAddSub() throws -> Double {
            var l = try parseMulDiv()
            while pos < chars.count, chars[pos] == "+" || chars[pos] == "-" {
                let op = chars[pos]; pos += 1; skipWS()
                let r = try parseMulDiv()
                l = op == "+" ? l + r : l - r
            }
            return l
        }
        mutating func parseMulDiv() throws -> Double {
            var l = try parsePow()
            while pos < chars.count, chars[pos] == "*" || chars[pos] == "/" || chars[pos] == "%" {
                let op = chars[pos]; pos += 1; skipWS()
                let r = try parsePow()
                if (op == "/" || op == "%") && r == 0 {
                    throw Error("divide by zero")
                }
                switch op {
                case "*": l = l * r
                case "/": l = l / r
                default:  l = l.truncatingRemainder(dividingBy: r)
                }
            }
            return l
        }
        mutating func parsePow() throws -> Double {
            let base = try parseUnary()
            if pos < chars.count, chars[pos] == "^" {
                pos += 1; skipWS()
                let exp = try parsePow()  // right-associative
                return pow(base, exp)
            }
            return base
        }
        mutating func parseUnary() throws -> Double {
            if pos < chars.count, chars[pos] == "-" {
                pos += 1; skipWS()
                return -(try parseUnary())
            }
            if pos < chars.count, chars[pos] == "+" {
                pos += 1; skipWS()
                return try parseUnary()
            }
            if pos < chars.count, chars[pos] == "!" {
                pos += 1; skipWS()
                return try parseUnary() == 0 ? 1 : 0
            }
            return try parsePrimary()
        }
        mutating func parsePrimary() throws -> Double {
            skipWS()
            guard pos < chars.count else {
                throw Error("syntax error: unexpected end")
            }
            if chars[pos] == "(" {
                pos += 1; skipWS()
                let v = try parseExpr()
                skipWS()
                guard pos < chars.count, chars[pos] == ")" else {
                    throw Error("missing `)`")
                }
                pos += 1; skipWS()
                return v
            }
            if chars[pos].isNumber || chars[pos] == "." {
                return parseNumber()
            }
            if isIdentChar(chars[pos], first: true) {
                let start = pos
                while pos < chars.count, isIdentChar(chars[pos], first: false) { pos += 1 }
                let name = String(chars[start..<pos])
                skipWS()
                if pos < chars.count, chars[pos] == "(" {
                    pos += 1; skipWS()
                    var args: [Double] = []
                    if pos < chars.count, chars[pos] != ")" {
                        args.append(try parseExpr())
                        while pos < chars.count, chars[pos] == "," {
                            pos += 1; skipWS()
                            args.append(try parseExpr())
                        }
                    }
                    skipWS()
                    guard pos < chars.count, chars[pos] == ")" else {
                        throw Error("missing `)`")
                    }
                    pos += 1; skipWS()
                    return try callBuiltin(name: name, args: args)
                }
                if name == "scale" { return Double(ctx.scale) }
                return ctx.vars[name] ?? 0
            }
            throw Error("unexpected character `\(chars[pos])`")
        }

        mutating func parseNumber() -> Double {
            let start = pos
            while pos < chars.count, chars[pos].isNumber || chars[pos] == "." { pos += 1 }
            // Optional e/E exponent.
            if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
                pos += 1
                if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { pos += 1 }
                while pos < chars.count, chars[pos].isNumber { pos += 1 }
            }
            let s = String(chars[start..<pos])
            skipWS()
            return Double(s) ?? 0
        }

        func callBuiltin(name: String, args: [Double]) throws -> Double {
            switch name {
            case "sqrt":
                guard args.count == 1 else { throw Error("sqrt requires 1 argument") }
                return args[0].squareRoot()
            case "length":
                guard args.count == 1 else { throw Error("length requires 1 argument") }
                return Double(String(Int64(args[0].rounded(.towardZero))).count)
            case "scale":
                guard args.count == 1 else { throw Error("scale requires 1 argument") }
                let s = "\(args[0])"
                if let dot = s.firstIndex(of: ".") {
                    return Double(s.distance(from: s.index(after: dot), to: s.endIndex))
                }
                return 0
            case "s":   return sin(args[0])
            case "c":   return cos(args[0])
            case "a":   return atan(args[0])
            case "l":   return log(args[0])
            case "e":   return exp(args[0])
            case "abs": return abs(args[0])
            default:
                throw Error("unknown function: \(name)")
            }
        }

        // MARK: helpers

        mutating func skipWS() {
            while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
        }
        func peek(_ offset: Int) -> Character? {
            let i = pos + offset
            return i < chars.count ? chars[i] : nil
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
        func isIdentChar(_ c: Character, first: Bool) -> Bool {
            if c.isASCII && c.isLetter { return true }
            if c == "_" { return true }
            if !first && c.isASCII && c.isNumber { return true }
            return false
        }
    }
}
