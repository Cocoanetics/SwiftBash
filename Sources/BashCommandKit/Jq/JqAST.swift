import Foundation

/// AST nodes produced by ``JqParser``. Indirect because most variants
/// are recursive (pipes, calls, conditionals).
public indirect enum JqAST: Sendable {
    case identity
    case recurse                       // ..
    case field(name: String, base: JqAST?)
    case index(index: JqAST, base: JqAST?)
    case slice(start: JqAST?, end: JqAST?, base: JqAST?)
    case iterate(base: JqAST?)
    case literal(JqValue)
    case array(JqAST?)                 // [.foo] -> .array(.field("foo", nil))
    case object([JqObjectEntry])
    case paren(JqAST)
    case pipe(JqAST, JqAST)
    case comma(JqAST, JqAST)
    case binaryOp(JqBinaryOp, JqAST, JqAST)
    case unaryOp(JqUnaryOp, JqAST)
    case cond(cond: JqAST, then: JqAST, elifs: [(JqAST, JqAST)], else_: JqAST?)
    case try_(body: JqAST, catch_: JqAST?)
    case call(name: String, args: [JqAST])
    case varBind(pattern: JqPattern, alternatives: [JqPattern], value: JqAST, body: JqAST)
    case varRef(String)               // $name (with $ prefix)
    case optional(JqAST)              // expr?
    case stringInterp([JqStringPart])
    case updateOp(JqUpdateOp, path: JqAST, value: JqAST)
    case reduce(expr: JqAST, pattern: JqPattern, init_: JqAST, update: JqAST)
    case foreach(expr: JqAST, pattern: JqPattern, init_: JqAST, update: JqAST, extract: JqAST?)
    case label(String, JqAST)
    case break_(String)
    case def(name: String, params: [String], funcBody: JqAST, body: JqAST)
    case format(name: String, interp: [JqStringPart]?)  // @csv, @json, @base64 ...
}

public struct JqObjectEntry: Sendable {
    public enum Key: Sendable {
        case literal(String)
        case computed(JqAST)
    }
    public let key: Key
    public let value: JqAST

    public init(key: Key, value: JqAST) {
        self.key = key
        self.value = value
    }
}

public enum JqStringPart: Sendable {
    case literal(String)
    case interp(JqAST)
}

public enum JqBinaryOp: String, Sendable {
    case add = "+", sub = "-", mul = "*", div = "/", mod = "%"
    case eq = "==", ne = "!=", lt = "<", le = "<=", gt = ">", ge = ">="
    case and, or, alt = "//"
}

public enum JqUnaryOp: String, Sendable {
    case neg = "-", not = "not"
}

public enum JqUpdateOp: String, Sendable {
    case assign = "="
    case addAssign = "+="
    case subAssign = "-="
    case mulAssign = "*="
    case divAssign = "/="
    case modAssign = "%="
    case altAssign = "//="
    case pipeAssign = "|="
}

/// Destructuring pattern for `as` binding.
public indirect enum JqPattern: Sendable {
    case variable(String)                              // $name (with $ prefix)
    case array([JqPattern])                            // [$a, $b, ...]
    case object([JqPatternField])                      // {key: $a, $b, ...}
}

public struct JqPatternField: Sendable {
    public enum Key: Sendable {
        case literal(String)
        case computed(JqAST)
    }
    public let key: Key
    public let pattern: JqPattern
    public let keyVar: String?       // for `$b: [$c, $d]` shorthand

    public init(key: Key, pattern: JqPattern, keyVar: String? = nil) {
        self.key = key
        self.pattern = pattern
        self.keyVar = keyVar
    }
}
