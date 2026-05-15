import Foundation

/// Evaluation context: variable bindings, user-defined functions,
/// document root for parent/path tracking, plus iteration limits.
public final class JqContext {
    public var vars: [String: JqValue]
    public var env: [String: String]
    public var funcs: [String: JqFunc]
    public var labels: Set<String>
    public var root: JqValue?
    public var currentPath: [JqValue]
    public var maxIterations: Int

    public init(env: [String: String] = [:], maxIterations: Int = 1_000_000) {
        self.vars = [:]
        self.env = env
        self.funcs = [:]
        self.labels = []
        self.root = nil
        self.currentPath = []
        self.maxIterations = maxIterations
    }

    /// Snapshot used when forking the evaluator into a sub-scope so
    /// mutations to vars/funcs don't leak back to the caller.
    func fork() -> JqContext {
        let child = JqContext(env: env, maxIterations: maxIterations)
        child.vars = vars
        child.funcs = funcs
        child.labels = labels
        child.root = root
        child.currentPath = currentPath
        return child
    }
}

public struct JqFunc {
    public let params: [String]
    public let body: JqAST
    /// Lexical closure: function table at definition time.
    public let closure: [String: JqFunc]
}

/// Top-level evaluator. Each AST node returns a `[JqValue]` because jq
/// filters are streams (zero, one, or many results).
public struct JqEvaluator {

    public static func evaluate(_ value: JqValue,
                                _ ast: JqAST,
                                ctx: JqContext) throws -> [JqValue] {
        if ctx.root == nil {
            ctx.root = value
            ctx.currentPath = []
        }
        return try evalNode(value, ast, ctx)
    }

    // The dispatch switch is intrinsically large: each jq AST variant
    // gets its own clause and the rules below would force splitting
    // into per-case helpers with no readability win.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func evalNode(_ value: JqValue,
                         _ ast: JqAST,
                         _ ctx: JqContext) throws -> [JqValue] {
        switch ast {
        case .identity:
            return [value]
        case .recurse:
            return evalRecurse(value)
        case .field(let name, let base):
            return try evalField(value, name: name, base: base, ctx: ctx)
        case .index(let indexExpr, let base):
            return try evalIndex(value, indexExpr: indexExpr, base: base, ctx: ctx)
        case .slice(let startAST, let endAST, let base):
            return try evalSlice(value, startAST: startAST, endAST: endAST, base: base, ctx: ctx)
        case .iterate(let base):
            return try evalIterate(value, base: base, ctx: ctx)
        case .pipe(let left, let right):
            return try evalPipe(value, left: left, right: right, ctx: ctx)
        case .comma(let left, let right):
            return try evalNode(value, left, ctx) + evalNode(value, right, ctx)
        case .literal(let literalValue):
            return [literalValue]
        case .array(let body):
            guard let body else { return [.array([])] }
            let elems = try evalNode(value, body, ctx)
            return [.array(elems)]
        case .object(let entries):
            return try evalObject(value, entries, ctx)
        case .paren(let inner):
            return try evalNode(value, inner, ctx)
        case .binaryOp(let binOp, let left, let right):
            return try evalBinary(value, binOp, left, right, ctx)
        case .unaryOp(let unaryOp, let operand):
            return try evalUnary(value, unaryOp: unaryOp, operand: operand, ctx: ctx)
        case .cond:
            return try evalCond(value, ast: ast, ctx: ctx)
        case .try_:
            return try evalTry(value, ast: ast, ctx: ctx)
        case .call(let name, let args):
            return try JqBuiltins.evaluate(value, name: name, args: args, ctx: ctx)
        case .varBind:
            return try evalVarBind(value, ast: ast, ctx: ctx)
        case .varRef(let name):
            return try evalVarRef(name: name, ctx: ctx)
        case .optional(let expr):
            return try evalOptional(value, expr: expr, ctx: ctx)
        case .stringInterp(let parts):
            return [evalStringInterp(value, parts, ctx)]
        case .updateOp(let updateOp, let path, let valueExpr):
            return [try applyUpdate(value, path, updateOp, valueExpr, ctx)]
        case .reduce:
            return try evalReduce(value, ast: ast, ctx: ctx)
        case .foreach:
            return try evalForeach(value, ast: ast, ctx: ctx)
        case .label(let name, let body):
            return try evalLabel(value, name: name, body: body, ctx: ctx)
        case .break_(let name):
            throw JqBreak(label: name)
        case .def:
            return try evalDef(value, ast: ast, ctx: ctx)
        case .format(let name, let interp):
            return try JqFormatBuiltins.evaluate(value, name: name, interp: interp, ctx: ctx)
        }
    }
}
