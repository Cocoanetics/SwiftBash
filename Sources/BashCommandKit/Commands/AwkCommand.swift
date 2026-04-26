import ArgumentParser
import BashInterpreter
import Foundation

/// `awk [OPTIONS] 'PROGRAM' [FILE...]` — pattern-scanning language.
///
/// A native Swift implementation that mirrors gawk/mawk behaviour for
/// the POSIX surface plus common extensions: full expression evaluator
/// with proper precedence (assignment / ternary / pipe-getline / or /
/// and / in / concat / match / comparison / add / mul / unary / power /
/// postfix), patterns (BEGIN / END / regex / expr / range), built-in
/// scalars (FS / OFS / ORS / OFMT / NR / NF / FNR / FILENAME / RSTART /
/// RLENGTH / SUBSEP / ARGC / ARGV / ENVIRON), arrays with multi-dim
/// SUBSEP keys and pass-by-ref to user functions, control flow
/// (if / while / do-while / for / for-in / break / continue / next /
/// nextfile / exit / return), text I/O (print / printf / getline with
/// file and command-pipe variants, redirection to file via `>` `>>`),
/// and the standard built-in library (length / substr / index / split /
/// sub / gsub / gensub / match / tolower / toupper / sprintf / int /
/// sqrt / sin / cos / atan2 / log / exp / rand / srand / systime /
/// mktime / strftime).
///
/// Options:
///   `-F FS`            field separator (regex; common single-char
///                      forms work as literals)
///   `-v VAR=VALUE`     pre-set a variable before BEGIN
///   `-f FILE`          read program from FILE (repeatable)
///
/// `system()` is intentionally disabled. `"cmd" | getline` returns -1
/// in this sandbox. Files opened via `print > "file"` accumulate
/// in-process and flush at end; truncate-then-append semantics match
/// real awk.
public struct AwkCommand: ParsableBashCommand {
    public static let configuration = CommandConfiguration(
        commandName: "awk",
        abstract: "Pattern scanning and text processing language."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "OPTIONS, PROGRAM, FILE…")
    public var rawArgv: [String] = []

    public init() {}

    public mutating func execute() async throws -> ExitStatus {
        var fieldSep = " "
        var presetVars: [(String, String)] = []
        var programs: [String] = []
        var files: [String] = []

        var i = 0
        while i < rawArgv.count {
            let a = rawArgv[i]
            if a == "-F" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("awk: -F requires an argument\n"); return ExitStatus(2)
                }
                fieldSep = processEscapes(rawArgv[i + 1])
                i += 2; continue
            }
            if a.hasPrefix("-F") && a.count > 2 {
                fieldSep = processEscapes(String(a.dropFirst(2)))
                i += 1; continue
            }
            if a == "-v" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("awk: -v requires NAME=VALUE\n"); return ExitStatus(2)
                }
                let assn = rawArgv[i + 1]
                if let eq = assn.firstIndex(of: "=") {
                    let name = String(assn[..<eq])
                    let value = processEscapes(String(assn[assn.index(after: eq)...]))
                    presetVars.append((name, value))
                }
                i += 2; continue
            }
            if a == "-f" {
                guard i + 1 < rawArgv.count else {
                    Shell.current.stderr("awk: -f requires a file\n"); return ExitStatus(2)
                }
                do {
                    let data = try await Shell.current.readDataAtPath(rawArgv[i + 1])
                    programs.append(String(decoding: data, as: UTF8.self))
                } catch {
                    Shell.current.stderr("awk: can't open \(rawArgv[i + 1]): \(error)\n")
                    return ExitStatus(2)
                }
                i += 2; continue
            }
            if a == "--" {
                i += 1
                if programs.isEmpty, i < rawArgv.count {
                    programs.append(rawArgv[i]); i += 1
                }
                while i < rawArgv.count { files.append(rawArgv[i]); i += 1 }
                continue
            }
            if a.hasPrefix("-") && a != "-" {
                Shell.current.stderr("awk: unknown option: \(a)\n"); return ExitStatus(2)
            }
            if programs.isEmpty {
                programs.append(a)
            } else {
                files.append(a)
            }
            i += 1
        }

        guard !programs.isEmpty else {
            Shell.current.stderr("awk: missing program\n")
            return ExitStatus(2)
        }
        let source = programs.joined(separator: "\n")

        let program: AwkProgram
        do {
            program = try AwkParser.parse(source)
        } catch let e as AwkParseError {
            Shell.current.stderr("awk: \(e.message)\n")
            return ExitStatus(2)
        }

        // Pre-load any files referenced by `getline < "file"` as well
        // as the input files themselves.
        let ctx = AwkContext()
        ctx.cwd = Shell.current.environment.workingDirectory
        ctx.FS = fieldSep
        for (name, value) in presetVars { ctx.vars[name] = .string(value) }
        // ENVIRON
        for (k, v) in Shell.current.environment.variables { ctx.ENVIRON[k] = .string(v) }
        // ARGC/ARGV
        ctx.ARGC = files.count + 1
        ctx.ARGV["0"] = .string("awk")
        for (i, f) in files.enumerated() { ctx.ARGV[String(i + 1)] = .string(f) }

        // Inject a sync file reader (for getline < file). We can't do
        // async in the inner loop, so cache up-front from the shell's
        // FS where requested.
        // Simplest: read on demand via the shell, but the executor is
        // sync. So we load lazily through `readFile` here. Since we
        // can't await inside, we use a captured closure that throws if
        // called during execution; pre-warm any literal `getline <
        // "file"` targets up front.
        var preloadedFiles: [String: String] = [:]
        for path in collectGetlineTargets(program) {
            do {
                let resolved = path.hasPrefix("/") ? path : ctx.cwd + "/" + path
                let data = try await Shell.current.readDataAtPath(resolved)
                preloadedFiles[resolved] = String(decoding: data, as: UTF8.self)
                preloadedFiles[path] = preloadedFiles[resolved]
            } catch {
                // Missing file → empty content.
                preloadedFiles[path] = ""
            }
        }
        ctx.readFile = { path in
            if let c = preloadedFiles[path] { return c }
            throw AwkRuntimeError("can't open \(path)")
        }
        ctx.resolvePath = { cwd, p in
            p.hasPrefix("/") ? p : (cwd.hasSuffix("/") ? cwd + p : cwd + "/" + p)
        }

        let interp = AwkInterpreter(program: program, ctx: ctx)

        let hasMain = program.rules.contains { rule in
            switch rule.pattern {
            case .begin, .end: return false
            default: return true
            }
        }
        let hasEnd = program.rules.contains { rule in
            if case .end = rule.pattern { return true } else { return false }
        }

        do {
            try interp.executeBegin()
            if ctx.shouldExit {
                try interp.executeEnd()
                Shell.current.stdout(ctx.output)
                try await flushFileWrites(ctx)
                return ExitStatus(Int32(ctx.exitCode))
            }
            if hasMain || hasEnd {
                // Read all inputs into a single line array (per file we
                // also keep filename / FNR). For multiple files we
                // sequence them, resetting FNR between.
                if files.isEmpty {
                    let stdin = await Shell.current.stdin.readAllString()
                    var lines = stdin.components(separatedBy: "\n")
                    if lines.last == "" { lines.removeLast() }
                    ctx.FILENAME = ""
                    ctx.FNR = 0
                    ctx.lines = lines
                    ctx.lineIndex = -1
                    try processLines(interp: interp)
                } else {
                    for f in files {
                        if ctx.shouldExit { break }
                        let chunk: String
                        if f == "-" {
                            chunk = await Shell.current.stdin.readAllString()
                        } else {
                            do {
                                let data = try await Shell.current.readDataAtPath(f)
                                chunk = String(decoding: data, as: UTF8.self)
                            } catch {
                                Shell.current.stderr("awk: \(f): No such file or directory\n")
                                return ExitStatus(2)
                            }
                        }
                        var lines = chunk.components(separatedBy: "\n")
                        if lines.last == "" { lines.removeLast() }
                        ctx.FILENAME = f
                        ctx.FNR = 0
                        ctx.lines = lines
                        ctx.lineIndex = -1
                        ctx.shouldNextFile = false
                        try processLines(interp: interp)
                    }
                }
            }
            try interp.executeEnd()
        } catch let e as AwkRuntimeError {
            Shell.current.stderr("awk: \(e.message)\n")
            Shell.current.stdout(ctx.output)
            try await flushFileWrites(ctx)
            return ExitStatus(2)
        } catch {
            Shell.current.stderr("awk: \(error)\n")
            return ExitStatus(2)
        }

        Shell.current.stdout(ctx.output)
        try await flushFileWrites(ctx)
        return ExitStatus(Int32(ctx.exitCode))
    }

    private func processLines(interp: AwkInterpreter) throws {
        let ctx = interp.ctx
        while ctx.lineIndex < ctx.lines.count - 1 {
            ctx.lineIndex += 1
            try interp.executeLine(ctx.lines[ctx.lineIndex])
            if ctx.shouldExit || ctx.shouldNextFile { break }
        }
    }

    private func flushFileWrites(_ ctx: AwkContext) async throws {
        for (path, content) in ctx.fileWrites {
            try? await Shell.current.writeData(Data(content.utf8), toPath: path, append: false)
        }
    }

    /// Walk the AST collecting any string-literal arguments to
    /// `getline < <file>` so we can preload them before the
    /// synchronous interpreter runs.
    private func collectGetlineTargets(_ p: AwkProgram) -> Set<String> {
        var out = Set<String>()
        for fn in p.functions { collectStmts(fn.body, into: &out) }
        for r in p.rules { collectStmts(r.action, into: &out) }
        return out
    }
    private func collectStmts(_ stmts: [AwkStmt], into out: inout Set<String>) {
        for s in stmts { collectStmt(s, into: &out) }
    }
    private func collectStmt(_ s: AwkStmt, into out: inout Set<String>) {
        switch s {
        case .block(let inner): collectStmts(inner, into: &out)
        case .exprStmt(let e): collectExpr(e, into: &out)
        case .print(let args, let o):
            for a in args { collectExpr(a, into: &out) }
            if let o { collectExpr(o.target, into: &out) }
        case .printf(let f, let args, let o):
            collectExpr(f, into: &out)
            for a in args { collectExpr(a, into: &out) }
            if let o { collectExpr(o.target, into: &out) }
        case .ifStmt(let c, let t, let e):
            collectExpr(c, into: &out); collectStmt(t, into: &out)
            if let e { collectStmt(e, into: &out) }
        case .whileStmt(let c, let b): collectExpr(c, into: &out); collectStmt(b, into: &out)
        case .doWhile(let b, let c): collectStmt(b, into: &out); collectExpr(c, into: &out)
        case .forStmt(let i, let c, let u, let b):
            if let i { collectExpr(i, into: &out) }
            if let c { collectExpr(c, into: &out) }
            if let u { collectExpr(u, into: &out) }
            collectStmt(b, into: &out)
        case .forIn(_, _, let b): collectStmt(b, into: &out)
        case .exit(let c): if let c { collectExpr(c, into: &out) }
        case .return_(let v): if let v { collectExpr(v, into: &out) }
        default: break
        }
    }
    private func collectExpr(_ e: AwkExpr, into out: inout Set<String>) {
        switch e {
        case .getline(_, let file, _):
            if case .string(let s)? = file { out.insert(s) }
        case .binary(_, let l, let r):
            collectExpr(l, into: &out); collectExpr(r, into: &out)
        case .unary(_, let o): collectExpr(o, into: &out)
        case .ternary(let c, let t, let e):
            collectExpr(c, into: &out); collectExpr(t, into: &out); collectExpr(e, into: &out)
        case .call(_, let args):
            for a in args { collectExpr(a, into: &out) }
        case .assignment(_, _, let v): collectExpr(v, into: &out)
        case .field(let i): collectExpr(i, into: &out)
        case .arrayAccess(_, let k): collectExpr(k, into: &out)
        case .tuple(let es): for e in es { collectExpr(e, into: &out) }
        case .inExpr(let k, _): collectExpr(k, into: &out)
        default: break
        }
    }
}

private func processEscapes(_ s: String) -> String {
    s.replacingOccurrences(of: "\\t", with: "\t")
     .replacingOccurrences(of: "\\n", with: "\n")
     .replacingOccurrences(of: "\\r", with: "\r")
     .replacingOccurrences(of: "\\\\", with: "\\")
}
