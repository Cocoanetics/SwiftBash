import Foundation

/// AWK AST nodes. `indirect` because most variants are recursive
/// (binary ops, ternary, calls, etc.).
public indirect enum AwkExpr: Sendable {
    case number(Double)
    case string(String)
    case regex(String)
    case field(AwkExpr)                                  // $expr
    case variable(String)
    case arrayAccess(name: String, key: AwkExpr)
    case binary(AwkBinaryOp, AwkExpr, AwkExpr)
    case unary(AwkUnaryOp, AwkExpr)
    case ternary(AwkExpr, AwkExpr, AwkExpr)
    case call(name: String, args: [AwkExpr])
    case assignment(AwkAssignOp, target: AwkLValue, value: AwkExpr)
    case preIncrement(AwkLValue)
    case preDecrement(AwkLValue)
    case postIncrement(AwkLValue)
    case postDecrement(AwkLValue)
    case getline(variable: String?, file: AwkExpr?, command: AwkExpr?)
    case inExpr(key: AwkExpr, array: String)
    case tuple([AwkExpr])                                // for (a,b) in arr
}

/// Assignable expression — left-hand side of `=` / `+=` / `++`.
public enum AwkLValue: Sendable {
    case variable(String)
    case field(AwkExpr)
    case arrayAccess(name: String, key: AwkExpr)
}

public enum AwkBinaryOp: String, Sendable {
    case add = "+", sub = "-", mul = "*", div = "/", mod = "%", pow = "^"
    // Two-letter comparison ops mirror AWK source-level spellings.
    // swiftlint:disable:next identifier_name
    case eq = "==", ne = "!=", lt = "<", le = "<=", gt = ">", ge = ">="
    case match = "~", notMatch = "!~"
    // `or` mirrors the boolean operator spelling.
    // swiftlint:disable:next identifier_name
    case and = "&&", or = "||"
    case concat = " "
}

public enum AwkUnaryOp: String, Sendable {
    case not = "!", neg = "-", pos = "+"
}

public enum AwkAssignOp: String, Sendable {
    case assign = "="
    case addAssign = "+="
    case subAssign = "-="
    case mulAssign = "*="
    case divAssign = "/="
    case modAssign = "%="
    case powAssign = "^="
}

// MARK: - Statements

public indirect enum AwkStmt: Sendable {
    case block([AwkStmt])
    case exprStmt(AwkExpr)
    case print(args: [AwkExpr], output: AwkOutput?)
    case printf(format: AwkExpr, args: [AwkExpr], output: AwkOutput?)
    // `else_` mirrors the AWK source keyword while remaining a valid Swift identifier.
    // swiftlint:disable:next identifier_name
    case ifStmt(cond: AwkExpr, then: AwkStmt, else_: AwkStmt?)
    case whileStmt(cond: AwkExpr, body: AwkStmt)
    case doWhile(body: AwkStmt, cond: AwkExpr)
    // `init_` mirrors the AWK source keyword while remaining a valid Swift identifier.
    // swiftlint:disable:next identifier_name
    case forStmt(init_: AwkExpr?, cond: AwkExpr?, update: AwkExpr?, body: AwkStmt)
    case forIn(variable: String, array: String, body: AwkStmt)
    // `break_`, `continue_`, `return_` mirror reserved Swift keywords.
    // swiftlint:disable:next identifier_name
    case break_
    // swiftlint:disable:next identifier_name
    case continue_
    case next
    case nextfile
    case exit(code: AwkExpr?)
    // swiftlint:disable:next identifier_name
    case return_(value: AwkExpr?)
    case delete(target: AwkLValue)
}

public struct AwkOutput: Sendable {
    public enum Kind: String, Sendable {
        case write = ">"           // overwrite (then append on subsequent writes)
        case append = ">>"
        case pipe = "|"            // print | "cmd"
    }
    public let kind: Kind
    public let target: AwkExpr
}

// MARK: - Patterns + Rules

public indirect enum AwkPattern: Sendable {
    case begin
    case end
    case beginfile
    case endfile
    case expr(AwkExpr)
    case regex(String)
    case range(start: AwkPattern, end: AwkPattern)
}

public struct AwkRule: Sendable {
    public var pattern: AwkPattern?
    public var action: [AwkStmt]      // statements of the action block

    public init(pattern: AwkPattern? = nil, action: [AwkStmt]) {
        self.pattern = pattern
        self.action = action
    }
}

public struct AwkFunction: Sendable {
    public var name: String
    public var params: [String]
    public var body: [AwkStmt]
}

public struct AwkProgram: Sendable {
    public var functions: [AwkFunction]
    public var rules: [AwkRule]

    public init(functions: [AwkFunction] = [], rules: [AwkRule] = []) {
        self.functions = functions
        self.rules = rules
    }
}

// MARK: - Errors

public struct AwkParseError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct AwkRuntimeError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
