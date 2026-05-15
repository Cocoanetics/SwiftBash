import Foundation

/// Statement executor — drives blocks, control flow, print / printf,
/// and file / pipe redirections. Buffered output goes onto
/// `ctx.output`; per-file / per-pipe writes go into context-managed
/// caches that the host flushes when the program ends.
enum AwkStatements {

    static func executeBlock(_ ctx: AwkContext, _ stmts: [AwkStmt]) throws {
        for stmt in stmts {
            try executeStmt(ctx, stmt)
            if shouldBreak(ctx) { break }
        }
    }

    private static func shouldBreak(_ ctx: AwkContext) -> Bool {
        ctx.shouldExit || ctx.shouldNext || ctx.shouldNextFile
        || ctx.loopBreak || ctx.loopContinue || ctx.hasReturn
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func executeStmt(_ ctx: AwkContext, _ stmt: AwkStmt) throws {
        switch stmt {
        case .block(let inner):
            try executeBlock(ctx, inner)
        case .exprStmt(let expr):
            _ = try AwkExpressions.eval(ctx, expr)
        case .print(let args, let output):
            try executePrint(ctx, args, output)
        case .printf(let format, let args, let output):
            try executePrintf(ctx, format, args, output)
        case .ifStmt(let cond, let thenStmt, let elseStmt):
            if try AwkExpressions.eval(ctx, cond).isTruthy {
                try executeStmt(ctx, thenStmt)
            } else if let elseStmt { try executeStmt(ctx, elseStmt) }
        case .whileStmt(let cond, let body):
            var count = 0
            while try AwkExpressions.eval(ctx, cond).isTruthy {
                count += 1
                if count > ctx.maxIterations {
                    throw AwkRuntimeError("while loop exceeded max iterations")
                }
                ctx.loopContinue = false
                try executeStmt(ctx, body)
                if ctx.loopBreak { ctx.loopBreak = false; break }
                if ctx.shouldExit || ctx.shouldNext || ctx.hasReturn { break }
            }
        case .doWhile(let body, let cond):
            var count = 0
            repeat {
                count += 1
                if count > ctx.maxIterations {
                    throw AwkRuntimeError("do-while loop exceeded max iterations")
                }
                ctx.loopContinue = false
                try executeStmt(ctx, body)
                if ctx.loopBreak { ctx.loopBreak = false; break }
                if ctx.shouldExit || ctx.shouldNext || ctx.hasReturn { break }
            } while try AwkExpressions.eval(ctx, cond).isTruthy
            // swiftlint:disable:next identifier_name - `init_` mirrors Swift's reserved word
        case .forStmt(let init_, let cond, let upd, let body):
            if let initExpr = init_ { _ = try AwkExpressions.eval(ctx, initExpr) }
            var count = 0
            while true {
                if let condExpr = cond {
                    if !(try AwkExpressions.eval(ctx, condExpr).isTruthy) { break }
                }
                count += 1
                if count > ctx.maxIterations {
                    throw AwkRuntimeError("for loop exceeded max iterations")
                }
                ctx.loopContinue = false
                try executeStmt(ctx, body)
                if ctx.loopBreak { ctx.loopBreak = false; break }
                if ctx.shouldExit || ctx.shouldNext || ctx.hasReturn { break }
                if let updExpr = upd { _ = try AwkExpressions.eval(ctx, updExpr) }
            }
        case .forIn(let varName, let arr, let body):
            let resolved = AwkExpressions.resolveArray(ctx, arr)
            guard let array = ctx.arrays[resolved] else { return }
            for key in array.keys {
                ctx.vars[varName] = .string(key)
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
            if let codeExpr = code {
                ctx.exitCode = Int(try AwkExpressions.eval(ctx, codeExpr).asNumber.rounded(.towardZero))
            }
        case .return_(let value):
            ctx.hasReturn = true
            ctx.returnValue = value != nil ? try AwkExpressions.eval(ctx, value!) : .empty
        case .delete(let target):
            switch target {
            case .arrayAccess(let name, let key):
                AwkExpressions.deleteArrayElement(ctx, name, try AwkExpressions.eval(ctx, key).asString)
            case .variable(let name):
                AwkExpressions.deleteArray(ctx, name)
            case .field:
                throw AwkRuntimeError("cannot delete a field")
            }
        }
    }

    // MARK: - Print

    private static func executePrint(_ ctx: AwkContext, _ args: [AwkExpr], _ output: AwkOutput?) throws {
        var pieces: [String] = []
        for arg in args {
            let value = try AwkExpressions.eval(ctx, arg)
            pieces.append(formatForPrint(ctx, value))
        }
        let text = pieces.joined(separator: ctx.OFS) + ctx.ORS
        try writeOutput(ctx, output, text)
    }

    private static func executePrintf(_ ctx: AwkContext, _ format: AwkExpr,
                                      _ args: [AwkExpr], _ output: AwkOutput?) throws {
        let fmt = try AwkExpressions.eval(ctx, format).asString
        var values: [AwkValue] = []
        for arg in args { values.append(try AwkExpressions.eval(ctx, arg)) }
        try writeOutput(ctx, output, AwkPrintf.format(fmt, values: values))
    }

    /// Numbers print exactly when integral; otherwise via OFMT.
    private static func formatForPrint(_ ctx: AwkContext, _ value: AwkValue) -> String {
        switch value {
        case .number(let num):
            if num == num.rounded() && abs(num) < Double(Int64.max) {
                return String(Int64(num))
            }
            return AwkPrintf.format(ctx.OFMT, values: [.number(num)])
        case .string(let str): return str
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
