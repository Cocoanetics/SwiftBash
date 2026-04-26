import ArgumentParser
import BashInterpreter
import Foundation

/// `expr ARG...` — evaluate a POSIX expression and print its value.
///
/// Operators (lowest to highest precedence):
///   `|` — OR (returns left if non-zero/non-empty, else right)
///   `&` — AND (returns left if both non-empty/non-zero, else `0`)
///   `=` `!=` `<` `>` `<=` `>=` — numeric if both sides parse, else string
///   `+` `-`
///   `*` `/` `%`
///   `:` — `STRING : REGEX` matches REGEX anchored at the start.
///         If the pattern has a capture group, returns the group's
///         contents; otherwise returns the length of the matched
///         prefix (or `0` for no match).
///   `( EXPR )` — grouping
///
/// String functions:
///   `match STRING REGEX`
///   `substr STRING POS LEN`        (1-based)
///   `index STRING CHARS`           (1-based, 0 for not found)
///   `length STRING`
///
/// Exit status: `0` if the result is non-zero / non-empty; `1` if it
/// is `0` or empty; `2` on syntax error.
public struct ExprCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "expr",
        abstract: "Evaluate expression."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "Expression operands.")
    public var operands: [String] = []

    public init() {}

    public mutating func execute(shell: Shell) async throws -> ExitStatus {
        guard !operands.isEmpty else {
            shell.stderr("expr: missing operand\n")
            return ExitStatus(2)
        }
        var parser = ExprParser(args: operands)
        let result: String
        do {
            result = try parser.parseOr()
            if !parser.atEnd {
                throw ExprError("syntax error: \(parser.peek() ?? "")")
            }
        } catch let e as ExprError {
            shell.stderr("expr: \(e.message)\n")
            return ExitStatus(2)
        }
        shell.stdout(result + "\n")
        return (result == "0" || result.isEmpty) ? ExitStatus(1) : .success
    }
}

private struct ExprError: Error { let message: String; init(_ m: String) { self.message = m } }

private struct ExprParser {
    let args: [String]
    var i: Int = 0
    var atEnd: Bool { i >= args.count }
    func peek() -> String? { i < args.count ? args[i] : nil }
    mutating func advance() -> String? {
        guard i < args.count else { return nil }
        let t = args[i]; i += 1; return t
    }

    mutating func parseOr() throws -> String {
        var left = try parseAnd()
        while peek() == "|" {
            i += 1
            let right = try parseAnd()
            if left == "0" || left.isEmpty { left = right }
        }
        return left
    }

    mutating func parseAnd() throws -> String {
        var left = try parseComparison()
        while peek() == "&" {
            i += 1
            let right = try parseComparison()
            if left == "0" || left.isEmpty || right == "0" || right.isEmpty {
                left = "0"
            }
        }
        return left
    }

    mutating func parseComparison() throws -> String {
        var left = try parseAddSub()
        let ops: Set<String> = ["=", "!=", "<", ">", "<=", ">="]
        while let op = peek(), ops.contains(op) {
            i += 1
            let right = try parseAddSub()
            let leftN = Int(left), rightN = Int(right)
            let numeric = leftN != nil && rightN != nil
            let result: Bool
            if numeric, let a = leftN, let b = rightN {
                switch op {
                case "=":  result = a == b
                case "!=": result = a != b
                case "<":  result = a < b
                case ">":  result = a > b
                case "<=": result = a <= b
                default:   result = a >= b
                }
            } else {
                switch op {
                case "=":  result = left == right
                case "!=": result = left != right
                case "<":  result = left < right
                case ">":  result = left > right
                case "<=": result = left <= right
                default:   result = left >= right
                }
            }
            left = result ? "1" : "0"
        }
        return left
    }

    mutating func parseAddSub() throws -> String {
        var left = try parseMulDiv()
        while let op = peek(), op == "+" || op == "-" {
            i += 1
            let right = try parseMulDiv()
            guard let a = Int(left), let b = Int(right) else {
                throw ExprError("non-integer argument")
            }
            left = String(op == "+" ? a + b : a - b)
        }
        return left
    }

    mutating func parseMulDiv() throws -> String {
        var left = try parseMatch()
        while let op = peek(), op == "*" || op == "/" || op == "%" {
            i += 1
            let right = try parseMatch()
            guard let a = Int(left), let b = Int(right) else {
                throw ExprError("non-integer argument")
            }
            if (op == "/" || op == "%") && b == 0 {
                throw ExprError("division by zero")
            }
            switch op {
            case "*": left = String(a * b)
            case "/": left = String(a / b)
            default:  left = String(a % b)
            }
        }
        return left
    }

    mutating func parseMatch() throws -> String {
        var left = try parsePrimary()
        while peek() == ":" {
            i += 1
            let pattern = try parsePrimary()
            let result = matchAnchored(pattern: pattern, in: left)
            left = result
        }
        return left
    }

    mutating func parsePrimary() throws -> String {
        guard let token = peek() else { throw ExprError("syntax error") }
        switch token {
        case "match":
            i += 1
            let str = try parsePrimary()
            let pat = try parsePrimary()
            return matchUnanchored(pattern: pat, in: str)
        case "substr":
            i += 1
            let str = try parsePrimary()
            let posStr = try parsePrimary()
            let lenStr = try parsePrimary()
            guard let pos = Int(posStr), let len = Int(lenStr) else {
                throw ExprError("non-integer argument")
            }
            if pos < 1 || len < 1 { return "" }
            let chars = Array(str)
            let start = pos - 1
            if start >= chars.count { return "" }
            let end = min(chars.count, start + len)
            return String(chars[start..<end])
        case "index":
            i += 1
            let str = try parsePrimary()
            let chars = try parsePrimary()
            for (idx, c) in str.enumerated() {
                if chars.contains(c) { return String(idx + 1) }
            }
            return "0"
        case "length":
            i += 1
            let str = try parsePrimary()
            return String(str.count)
        case "(":
            i += 1
            let r = try parseOr()
            guard peek() == ")" else { throw ExprError("syntax error: missing `)`") }
            i += 1
            return r
        default:
            i += 1
            return token
        }
    }

    /// `STRING : REGEX` — match REGEX anchored at the start of STRING.
    /// `expr` uses BRE syntax (`\(` `\)` for groups, `+` `?` literal),
    /// converted here to ERE via the sed regex helper.
    /// Returns the first capture group if any; otherwise the length of
    /// the matched prefix; `0` if no match.
    private func matchAnchored(pattern: String, in s: String) -> String {
        let ere = SedRegex.breToEre(pattern)
        let p = ere.hasPrefix("^") ? ere : "^" + ere
        guard let re = try? NSRegularExpression(pattern: p) else { return "0" }
        let nsstr = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: nsstr.length)) else {
            return "0"
        }
        if m.numberOfRanges > 1 {
            let r = m.range(at: 1)
            if r.location != NSNotFound { return nsstr.substring(with: r) }
        }
        return String(m.range.length)
    }

    /// `match STRING REGEX` — like the `:` operator but takes the
    /// pattern as-is (no implicit anchor). Real BSD/GNU expr's `match`
    /// also anchors; we follow that for compatibility.
    private func matchUnanchored(pattern: String, in s: String) -> String {
        matchAnchored(pattern: pattern, in: s)
    }
}
