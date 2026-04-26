import Foundation

/// Statement executor — drives blocks, control flow, print / printf,
/// and file / pipe redirections. Buffered output goes onto
/// `ctx.output`; per-file / per-pipe writes go into context-managed
/// caches that the host flushes when the program ends.
enum AwkStatements {

    static func executeBlock(_ ctx: AwkContext, _ stmts: [AwkStmt]) throws {
        for s in stmts {
            try executeStmt(ctx, s)
            if shouldBreak(ctx) { break }
        }
    }

    private static func shouldBreak(_ ctx: AwkContext) -> Bool {
        ctx.shouldExit || ctx.shouldNext || ctx.shouldNextFile
        || ctx.loopBreak || ctx.loopContinue || ctx.hasReturn
    }

    static func executeStmt(_ ctx: AwkContext, _ s: AwkStmt) throws {
        switch s {
        case .block(let inner):
            try executeBlock(ctx, inner)
        case .exprStmt(let e):
            _ = try AwkExpressions.eval(ctx, e)
        case .print(let args, let output):
            try executePrint(ctx, args, output)
        case .printf(let format, let args, let output):
            try executePrintf(ctx, format, args, output)
        case .ifStmt(let c, let t, let e):
            if try AwkExpressions.eval(ctx, c).isTruthy {
                try executeStmt(ctx, t)
            } else if let e { try executeStmt(ctx, e) }
        case .whileStmt(let c, let body):
            var n = 0
            while try AwkExpressions.eval(ctx, c).isTruthy {
                n += 1
                if n > ctx.maxIterations {
                    throw AwkRuntimeError("while loop exceeded max iterations")
                }
                ctx.loopContinue = false
                try executeStmt(ctx, body)
                if ctx.loopBreak { ctx.loopBreak = false; break }
                if ctx.shouldExit || ctx.shouldNext || ctx.hasReturn { break }
            }
        case .doWhile(let body, let c):
            var n = 0
            repeat {
                n += 1
                if n > ctx.maxIterations {
                    throw AwkRuntimeError("do-while loop exceeded max iterations")
                }
                ctx.loopContinue = false
                try executeStmt(ctx, body)
                if ctx.loopBreak { ctx.loopBreak = false; break }
                if ctx.shouldExit || ctx.shouldNext || ctx.hasReturn { break }
            } while try AwkExpressions.eval(ctx, c).isTruthy
        case .forStmt(let init_, let cond, let upd, let body):
            if let i = init_ { _ = try AwkExpressions.eval(ctx, i) }
            var n = 0
            while true {
                if let c = cond {
                    if !(try AwkExpressions.eval(ctx, c).isTruthy) { break }
                }
                n += 1
                if n > ctx.maxIterations {
                    throw AwkRuntimeError("for loop exceeded max iterations")
                }
                ctx.loopContinue = false
                try executeStmt(ctx, body)
                if ctx.loopBreak { ctx.loopBreak = false; break }
                if ctx.shouldExit || ctx.shouldNext || ctx.hasReturn { break }
                if let u = upd { _ = try AwkExpressions.eval(ctx, u) }
            }
        case .forIn(let v, let arr, let body):
            let resolved = AwkExpressions.resolveArray(ctx, arr)
            guard let array = ctx.arrays[resolved] else { return }
            for key in array.keys {
                ctx.vars[v] = .string(key)
                ctx.loopContinue = false
                try executeStmt(ctx, body)
                if ctx.loopBreak { ctx.loopBreak = false; break }
                if ctx.shouldExit || ctx.shouldNext || ctx.hasReturn { break }
            }
        case .break_: ctx.loopBreak = true
        case .continue_: ctx.loopContinue = true
        case .next: ctx.shouldNext = true
        case .nextfile: ctx.shouldNextFile = true
        case .exit(let code):
            ctx.shouldExit = true
            if let c = code {
                ctx.exitCode = Int(try AwkExpressions.eval(ctx, c).asNumber.rounded(.towardZero))
            }
        case .return_(let v):
            ctx.hasReturn = true
            ctx.returnValue = v != nil ? try AwkExpressions.eval(ctx, v!) : .empty
        case .delete(let target):
            switch target {
            case .arrayAccess(let n, let k):
                AwkExpressions.deleteArrayElement(ctx, n, try AwkExpressions.eval(ctx, k).asString)
            case .variable(let n):
                AwkExpressions.deleteArray(ctx, n)
            case .field:
                throw AwkRuntimeError("cannot delete a field")
            }
        }
    }

    // MARK: - Print

    private static func executePrint(_ ctx: AwkContext, _ args: [AwkExpr], _ output: AwkOutput?) throws {
        var pieces: [String] = []
        for a in args {
            let v = try AwkExpressions.eval(ctx, a)
            pieces.append(formatForPrint(ctx, v))
        }
        let text = pieces.joined(separator: ctx.OFS) + ctx.ORS
        try writeOutput(ctx, output, text)
    }

    private static func executePrintf(_ ctx: AwkContext, _ format: AwkExpr,
                                      _ args: [AwkExpr], _ output: AwkOutput?) throws {
        let fmt = try AwkExpressions.eval(ctx, format).asString
        var values: [AwkValue] = []
        for a in args { values.append(try AwkExpressions.eval(ctx, a)) }
        try writeOutput(ctx, output, AwkPrintf.format(fmt, values: values))
    }

    /// Numbers print exactly when integral; otherwise via OFMT.
    private static func formatForPrint(_ ctx: AwkContext, _ v: AwkValue) -> String {
        switch v {
        case .number(let n):
            if n == n.rounded() && abs(n) < Double(Int64.max) {
                return String(Int64(n))
            }
            return AwkPrintf.format(ctx.OFMT, values: [.number(n)])
        case .string(let s): return s
        }
    }

    private static func writeOutput(_ ctx: AwkContext, _ output: AwkOutput?, _ text: String) throws {
        guard let out = output else {
            ctx.output += text
            return
        }
        let target = try AwkExpressions.eval(ctx, out.target).asString
        switch out.kind {
        case .write:
            let path = ctx.resolvePath(ctx.cwd, target)
            if !ctx.openedFiles.contains(path) {
                ctx.openedFiles.insert(path)
                ctx.fileWrites[path] = text
            } else {
                ctx.fileWrites[path, default: ""] += text
            }
        case .append:
            let path = ctx.resolvePath(ctx.cwd, target)
            ctx.openedFiles.insert(path)
            ctx.fileWrites[path, default: ""] += text
        case .pipe:
            ctx.pipeOutputs[target, default: ""] += text
        }
    }
}
