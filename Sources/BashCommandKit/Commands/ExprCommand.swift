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

    public mutating func execute() async throws -> ExitStatus {
        guard !operands.isEmpty else {
            Shell.bashCurrent.stderr("expr: missing operand\n")
            return ExitStatus(2)
        }
        var parser = ExprParser(args: operands)
        let result: String
        do {
            result = try parser.parseOr()
            if !parser.atEnd {
                throw ExprError("syntax error: \(parser.peek() ?? "")")
            }
        } catch let exprErr as ExprError {
            Shell.bashCurrent.stderr("expr: \(exprErr.message)\n")
            return ExitStatus(2)
        }
        Shell.bashCurrent.stdout(result + "\n")
        return (result == "0" || result.isEmpty) ? ExitStatus(1) : .success
    }
}

private struct ExprError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private struct ExprParser {
    let args: [String]
    var index: Int = 0
    var atEnd: Bool { index >= args.count }
    func peek() -> String? { index < args.count ? args[index] : nil }
    mutating func advance() -> String? {
        guard index < args.count else { return nil }
        let token = args[index]; index += 1; return token
    }

    mutating func parseOr() throws -> String {
        var left = try parseAnd()
        while peek() == "|" {
            index += 1
            let right = try parseAnd()
            if left == "0" || left.isEmpty { left = right }
        }
        return left
    }

    mutating func parseAnd() throws -> String {
        var left = try parseComparison()
        while peek() == "&" {
            index += 1
            let right = try parseComparison()
            if left == "0" || left.isEmpty || right == "0" || right.isEmpty {
                left = "0"
            }
        }
        return left
    }

    // POSIX expr comparison: six relops, dispatched twice (once for the
    // numeric path, once for the string path). One coherent switch is
    // clearer than per-op helpers shared across two type branches.
    // swiftlint:disable:next cyclomatic_complexity
    mutating func parseComparison() throws -> String {
        var left = try parseAddSub()
        let ops: Set<String> = ["=", "!=", "<", ">", "<=", ">="]
        while let cmpOp = peek(), ops.contains(cmpOp) {
            index += 1
            let right = try parseAddSub()
            let leftN = Int(left), rightN = Int(right)
            let numeric = leftN != nil && rightN != nil
            let result: Bool
            if numeric, let lhs = leftN, let rhs = rightN {
                switch cmpOp {
                case "=":  result = lhs == rhs
                case "!=": result = lhs != rhs
                case "<":  result = lhs < rhs
                case ">":  result = lhs > rhs
                case "<=": result = lhs <= rhs
                default:   result = lhs >= rhs
                }
            } else {
                switch cmpOp {
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
        while let addOp = peek(), addOp == "+" || addOp == "-" {
            index += 1
            let right = try parseMulDiv()
            guard let lhs = Int(left), let rhs = Int(right) else {
                throw ExprError("non-integer argument")
            }
            left = String(addOp == "+" ? lhs + rhs : lhs - rhs)
        }
        return left
    }

    mutating func parseMulDiv() throws -> String {
        var left = try parseMatch()
        while let mulOp = peek(), mulOp == "*" || mulOp == "/" || mulOp == "%" {
            index += 1
            let right = try parseMatch()
            guard let lhs = Int(left), let rhs = Int(right) else {
                throw ExprError("non-integer argument")
            }
            if (mulOp == "/" || mulOp == "%") && rhs == 0 {
                throw ExprError("division by zero")
            }
            switch mulOp {
            case "*": left = String(lhs * rhs)
            case "/": left = String(lhs / rhs)
            default:  left = String(lhs % rhs)
            }
        }
        return left
    }

    mutating func parseMatch() throws -> String {
        var left = try parsePrimary()
        while peek() == ":" {
            index += 1
            let pattern = try parsePrimary()
            let result = matchAnchored(pattern: pattern, in: left)
            left = result
        }
        return left
    }

    // POSIX expr primary: dispatch on the leading token name (match /
    // substr / index / length / `(`) or fall through to a literal.
    // Splitting per-builtin helpers would scatter the cursor advances.
    // swiftlint:disable:next cyclomatic_complexity
    mutating func parsePrimary() throws -> String {
        guard let token = peek() else { throw ExprError("syntax error") }
        switch token {
        case "match":
            index += 1
            let str = try parsePrimary()
            let pat = try parsePrimary()
            return matchUnanchored(pattern: pat, in: str)
        case "substr":
            index += 1
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
            index += 1
            let str = try parsePrimary()
            let chars = try parsePrimary()
            for (idx, char) in str.enumerated() where chars.contains(char) {
                return String(idx + 1)
            }
            return "0"
        case "length":
            index += 1
            let str = try parsePrimary()
            return String(str.count)
        case "(":
            index += 1
            let result = try parseOr()
            guard peek() == ")" else { throw ExprError("syntax error: missing `)`") }
            index += 1
            return result
        default:
            index += 1
            return token
        }
    }

    /// `STRING : REGEX` — match REGEX anchored at the start of STRING.
    /// `expr` uses BRE syntax (`\(` `\)` for groups, `+` `?` literal),
    /// converted here to ERE via the sed regex helper.
    /// Returns the first capture group if any; otherwise the length of
    /// the matched prefix; `0` if no match.
    private func matchAnchored(pattern: String, in str: String) -> String {
        let ere = SedRegex.breToEre(pattern)
        let anchored = ere.hasPrefix("^") ? ere : "^" + ere
        guard let regex = try? NSRegularExpression(pattern: anchored) else { return "0" }
        let nsstr = str as NSString
        guard let match = regex.firstMatch(in: str,
                                           range: NSRange(location: 0, length: nsstr.length))
        else {
            return "0"
        }
        if match.numberOfRanges > 1 {
            let groupRange = match.range(at: 1)
            if groupRange.location != NSNotFound { return nsstr.substring(with: groupRange) }
        }
        return String(match.range.length)
    }

    /// `match STRING REGEX` — like the `:` operator but takes the
    /// pattern as-is (no implicit anchor). Real BSD/GNU expr's `match`
    /// also anchors; we follow that for compatibility.
    private func matchUnanchored(pattern: String, in str: String) -> String {
        matchAnchored(pattern: pattern, in: str)
    }
}
