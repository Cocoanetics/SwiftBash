import Foundation

/// Glue that drives BEGIN → per-line → END for an AWK program. The
/// host (AwkCommand) feeds inputs and consumes the buffered stdout
/// output via `ctx.output`.
public final class AwkInterpreter {

    public let ctx: AwkContext
    let program: AwkProgram
    /// Range-pattern membership is per-rule (matched on each cycle).
    var rangeStates: [Bool]

    public init(program: AwkProgram, ctx: AwkContext) {
        self.program = program
        self.ctx = ctx
        self.rangeStates = Array(repeating: false, count: program.rules.count)
        for fn in program.functions { ctx.functions[fn.name] = fn }
    }

    public func executeBegin() throws {
        for rule in program.rules {
            if case .begin = rule.pattern {
                try AwkStatements.executeBlock(ctx, rule.action)
                if ctx.shouldExit { return }
            }
        }
    }

    public func executeLine(_ line: String) throws {
        if ctx.shouldExit { return }
        AwkFields.setLine(ctx, line)
        ctx.NR += 1
        ctx.FNR += 1
        ctx.shouldNext = false
        for (i, rule) in program.rules.enumerated() {
            if ctx.shouldExit || ctx.shouldNext || ctx.shouldNextFile { break }
            if let p = rule.pattern, case .begin = p { continue }
            if let p = rule.pattern, case .end = p { continue }
            if try matches(rule, ruleIndex: i) {
                try AwkStatements.executeBlock(ctx, rule.action)
            }
        }
    }

    public func executeEnd() throws {
        if ctx.inEndBlock { return }
        ctx.inEndBlock = true
        ctx.shouldExit = false  // exit shouldn't skip remaining END blocks
        for rule in program.rules {
            if case .end = rule.pattern {
                try AwkStatements.executeBlock(ctx, rule.action)
                if ctx.shouldExit { break }
            }
        }
        ctx.inEndBlock = false
    }

    private func matches(_ rule: AwkRule, ruleIndex: Int) throws -> Bool {
        guard let pattern = rule.pattern else { return true }
        switch pattern {
        case .begin, .end, .beginfile, .endfile: return false
        case .regex(let p): return AwkExpressions.matchRegex(p, ctx.line)
        case .expr(let e): return try AwkExpressions.eval(ctx, e).isTruthy
        case .range(let s, let e):
            let startMatches = try matchPattern(s)
            let endMatches = try matchPattern(e)
            if !rangeStates[ruleIndex] {
                if startMatches {
                    rangeStates[ruleIndex] = true
                    if endMatches { rangeStates[ruleIndex] = false }
                    return true
                }
                return false
            } else {
                if endMatches { rangeStates[ruleIndex] = false }
                return true
            }
        }
    }

    private func matchPattern(_ p: AwkPattern) throws -> Bool {
        switch p {
        case .regex(let r): return AwkExpressions.matchRegex(r, ctx.line)
        case .expr(let e): return try AwkExpressions.eval(ctx, e).isTruthy
        default: return false
        }
    }
}
