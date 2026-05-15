import Foundation

/// `getline` family. Three flavours:
///   1. plain `getline [var]` — reads from current input stream
///   2. `getline [var] < "file"` — reads from a file
///   3. `"cmd" | getline [var]` — pipes a captured command's stdout
///
/// Returns 1 (got a line), 0 (EOF), or -1 (error).
enum AwkGetline {

    static func run(_ ctx: AwkContext,
                    variable: String?,
                    file: AwkExpr?,
                    command: AwkExpr?) throws -> AwkValue {
        if let cmd = command {
            return try fromCommand(ctx, variable: variable, command: cmd)
        }
        if let fileExpr = file {
            return try fromFile(ctx, variable: variable, file: fileExpr)
        }
        return fromMain(ctx, variable: variable)
    }

    /// Plain `getline` — advance through the current file's lines.
    /// Updates NR/FNR (via the executor: we increment NR ourselves and
    /// rely on the main loop to keep its lineIndex in sync).
    private static func fromMain(_ ctx: AwkContext, variable: String?) -> AwkValue {
        let next = ctx.lineIndex + 1
        if next >= ctx.lines.count { return .number(0) }
        let line = ctx.lines[next]
        if let varName = variable {
            ctx.vars[varName] = .string(line)
        } else {
            AwkFields.setLine(ctx, line)
        }
        ctx.NR += 1
        ctx.FNR += 1
        ctx.lineIndex = next
        return .number(1)
    }

    private static func fromFile(_ ctx: AwkContext, variable: String?, file: AwkExpr) throws -> AwkValue {
        let name = try AwkExpressions.eval(ctx, file).asString
        if name == "/dev/null" { return .number(0) }
        let path = ctx.resolvePath(ctx.cwd, name)
        if ctx.fileLines[path] == nil {
            do {
                let raw = try ctx.readFile(path)
                var lines = raw.components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }
                ctx.fileLines[path] = lines
                ctx.fileLineIndex[path] = -1
            } catch {
                return .number(-1)
            }
        }
        let pos = (ctx.fileLineIndex[path] ?? -1) + 1
        let lines = ctx.fileLines[path] ?? []
        if pos >= lines.count { return .number(0) }
        let line = lines[pos]
        ctx.fileLineIndex[path] = pos
        if let varName = variable {
            ctx.vars[varName] = .string(line)
        } else {
            AwkFields.setLine(ctx, line)
        }
        // NR is NOT updated for file getline.
        return .number(1)
    }

    private static func fromCommand(_ ctx: AwkContext, variable: String?, command: AwkExpr) throws -> AwkValue {
        // Command pipe getline: in this sandboxed runtime we don't
        // execute commands. Return -1 to signal failure (matches
        // just-bash when no `exec` provider is registered).
        _ = try AwkExpressions.eval(ctx, command)
        _ = variable
        return .number(-1)
    }
}
