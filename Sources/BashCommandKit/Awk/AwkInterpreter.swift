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
        for function in program.functions { ctx.functions[function.name] = function }
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
        for (ruleIndex, rule) in program.rules.enumerated() {
            if ctx.shouldExit || ctx.shouldNext || ctx.shouldNextFile { break }
            if let pattern = rule.pattern, case .begin = pattern { continue }
            if let pattern = rule.pattern, case .end = pattern { continue }
            if try matches(rule, ruleIndex: ruleIndex) {
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
        case .regex(let regex): return AwkExpressions.matchRegex(regex, ctx.line)
        case .expr(let expr): return try AwkExpressions.eval(ctx, expr).isTruthy
        case .range(let startPat, let endPat):
            let startMatches = try matchPattern(startPat)
            let endMatches = try matchPattern(endPat)
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

    private func matchPattern(_ pattern: AwkPattern) throws -> Bool {
        switch pattern {
        case .regex(let regex): return AwkExpressions.matchRegex(regex, ctx.line)
        case .expr(let expr): return try AwkExpressions.eval(ctx, expr).isTruthy
        default: return false
        }
    }
}
