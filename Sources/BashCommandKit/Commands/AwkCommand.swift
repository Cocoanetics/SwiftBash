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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public mutating func execute() async throws -> ExitStatus {
        var fieldSep = " "
        var presetVars: [(String, String)] = []
        var programs: [String] = []
        var files: [String] = []

        var idx = 0
        while idx < rawArgv.count {
            let arg = rawArgv[idx]
            if arg == "-F" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("awk: -F requires an argument\n"); return ExitStatus(2)
                }
                fieldSep = processEscapes(rawArgv[idx + 1])
                idx += 2; continue
            }
            if arg.hasPrefix("-F") && arg.count > 2 {
                fieldSep = processEscapes(String(arg.dropFirst(2)))
                idx += 1; continue
            }
            if arg == "-v" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("awk: -v requires NAME=VALUE\n"); return ExitStatus(2)
                }
                let assn = rawArgv[idx + 1]
                if let eqIdx = assn.firstIndex(of: "=") {
                    let name = String(assn[..<eqIdx])
                    let value = processEscapes(String(assn[assn.index(after: eqIdx)...]))
                    presetVars.append((name, value))
                }
                idx += 2; continue
            }
            if arg == "-f" {
                guard idx + 1 < rawArgv.count else {
                    Shell.bashCurrent.stderr("awk: -f requires a file\n"); return ExitStatus(2)
                }
                do {
                    let data = try await Shell.bashCurrent.readDataAtPath(rawArgv[idx + 1])
                    // awk scripts may legitimately contain non-UTF-8 byte sequences in string literals
                    // swiftlint:disable:next optional_data_string_conversion
                    programs.append(String(decoding: data, as: UTF8.self))
                } catch {
                    Shell.bashCurrent.stderr("awk: can't open \(rawArgv[idx + 1]): \(error)\n")
                    return ExitStatus(2)
                }
                idx += 2; continue
            }
            if arg == "--" {
                idx += 1
                if programs.isEmpty, idx < rawArgv.count {
                    programs.append(rawArgv[idx]); idx += 1
                }
                while idx < rawArgv.count { files.append(rawArgv[idx]); idx += 1 }
                continue
            }
            if arg.hasPrefix("-") && arg != "-" {
                Shell.bashCurrent.stderr("awk: unknown option: \(arg)\n"); return ExitStatus(2)
            }
            if programs.isEmpty {
                programs.append(arg)
            } else {
                files.append(arg)
            }
            idx += 1
        }

        guard !programs.isEmpty else {
            Shell.bashCurrent.stderr("awk: missing program\n")
            return ExitStatus(2)
        }
        let source = programs.joined(separator: "\n")

        let program: AwkProgram
        do {
            program = try AwkParser.parse(source)
        } catch let parseError as AwkParseError {
            Shell.bashCurrent.stderr("awk: \(parseError.message)\n")
            return ExitStatus(2)
        }

        // Pre-load any files referenced by `getline < "file"` as well
        // as the input files themselves.
        let ctx = AwkContext()
        ctx.cwd = Shell.bashCurrent.environment.workingDirectory
        ctx.FS = fieldSep
        for (name, value) in presetVars { ctx.vars[name] = .string(value) }
        // ENVIRON
        for (key, value) in Shell.bashCurrent.environment.variables { ctx.ENVIRON[key] = .string(value) }
        // ARGC/ARGV
        ctx.ARGC = files.count + 1
        ctx.ARGV["0"] = .string("awk")
        for (fileIdx, fileName) in files.enumerated() { ctx.ARGV[String(fileIdx + 1)] = .string(fileName) }

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
                let data = try await Shell.bashCurrent.readDataAtPath(resolved)
                // awk-style file input may contain partial/non-UTF-8 bytes
                // swiftlint:disable:next optional_data_string_conversion
                preloadedFiles[resolved] = String(decoding: data, as: UTF8.self)
                preloadedFiles[path] = preloadedFiles[resolved]
            } catch {
                // Missing file → empty content.
                preloadedFiles[path] = ""
            }
        }
        ctx.readFile = { path in
            if let cached = preloadedFiles[path] { return cached }
            throw AwkRuntimeError("can't open \(path)")
        }
        ctx.resolvePath = { cwd, path in
            path.hasPrefix("/") ? path : (cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path)
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
                Shell.bashCurrent.stdout(ctx.output)
                try await flushFileWrites(ctx)
                return ExitStatus(Int32(ctx.exitCode))
            }
            if hasMain || hasEnd {
                // Read all inputs into a single line array (per file we
                // also keep filename / FNR). For multiple files we
                // sequence them, resetting FNR between.
                if files.isEmpty {
                    let stdin = await Shell.bashCurrent.stdin.readAllString()
                    var lines = stdin.components(separatedBy: "\n")
                    if lines.last == "" { lines.removeLast() }
                    ctx.FILENAME = ""
                    ctx.FNR = 0
                    ctx.lines = lines
                    ctx.lineIndex = -1
                    try processLines(interp: interp)
                } else {
                    for file in files {
                        if ctx.shouldExit { break }
                        let chunk: String
                        if file == "-" {
                            chunk = await Shell.bashCurrent.stdin.readAllString()
                        } else {
                            do {
                                let data = try await Shell.bashCurrent.readDataAtPath(file)
                                // awk-style file input may contain partial/non-UTF-8 bytes
                                // swiftlint:disable:next optional_data_string_conversion
                                chunk = String(decoding: data, as: UTF8.self)
                            } catch {
                                Shell.bashCurrent.stderr("awk: \(file): No such file or directory\n")
                                return ExitStatus(2)
                            }
                        }
                        var lines = chunk.components(separatedBy: "\n")
                        if lines.last == "" { lines.removeLast() }
                        ctx.FILENAME = file
                        ctx.FNR = 0
                        ctx.lines = lines
                        ctx.lineIndex = -1
                        ctx.shouldNextFile = false
                        try processLines(interp: interp)
                    }
                }
            }
            try interp.executeEnd()
        } catch let runtimeError as AwkRuntimeError {
            Shell.bashCurrent.stderr("awk: \(runtimeError.message)\n")
            Shell.bashCurrent.stdout(ctx.output)
            try await flushFileWrites(ctx)
            return ExitStatus(2)
        } catch {
            Shell.bashCurrent.stderr("awk: \(error)\n")
            return ExitStatus(2)
        }

        Shell.bashCurrent.stdout(ctx.output)
        try await flushFileWrites(ctx)
        return ExitStatus(Int32(ctx.exitCode))
    }

    private func processLines(interp: AwkInterpreter) throws {
        let ctx = interp.ctx
        while ctx.lineIndex < ctx.lines.count - 1 {
            // Per-record cancellation check — `awk` over a huge file
            // can be aborted mid-stream.
            try Task.checkCancellation()
            ctx.lineIndex += 1
            try interp.executeLine(ctx.lines[ctx.lineIndex])
            if ctx.shouldExit || ctx.shouldNextFile { break }
        }
    }

    private func flushFileWrites(_ ctx: AwkContext) async throws {
        for (path, content) in ctx.fileWrites {
            try? await Shell.bashCurrent.writeData(Data(content.utf8), toPath: path, append: false)
        }
    }

    /// Walk the AST collecting any string-literal arguments to
    /// `getline < <file>` so we can preload them before the
    /// synchronous interpreter runs.
    private func collectGetlineTargets(_ program: AwkProgram) -> Set<String> {
        var out = Set<String>()
        for function in program.functions { collectStmts(function.body, into: &out) }
        for rule in program.rules { collectStmts(rule.action, into: &out) }
        return out
    }
    private func collectStmts(_ stmts: [AwkStmt], into out: inout Set<String>) {
        for stmt in stmts { collectStmt(stmt, into: &out) }
    }
    // swiftlint:disable:next cyclomatic_complexity
    private func collectStmt(_ stmt: AwkStmt, into out: inout Set<String>) {
        switch stmt {
        case .block(let inner): collectStmts(inner, into: &out)
        case .exprStmt(let expr): collectExpr(expr, into: &out)
        case .print(let args, let output):
            for arg in args { collectExpr(arg, into: &out) }
            if let output { collectExpr(output.target, into: &out) }
        case .printf(let format, let args, let output):
            collectExpr(format, into: &out)
            for arg in args { collectExpr(arg, into: &out) }
            if let output { collectExpr(output.target, into: &out) }
        case .ifStmt(let cond, let then, let alt):
            collectExpr(cond, into: &out); collectStmt(then, into: &out)
            if let alt { collectStmt(alt, into: &out) }
        case .whileStmt(let cond, let body): collectExpr(cond, into: &out); collectStmt(body, into: &out)
        case .doWhile(let body, let cond): collectStmt(body, into: &out); collectExpr(cond, into: &out)
        case .forStmt(let initExpr, let cond, let update, let body):
            if let initExpr { collectExpr(initExpr, into: &out) }
            if let cond { collectExpr(cond, into: &out) }
            if let update { collectExpr(update, into: &out) }
            collectStmt(body, into: &out)
        case .forIn(_, _, let body): collectStmt(body, into: &out)
        case .exit(let code): if let code { collectExpr(code, into: &out) }
        case .return_(let value): if let value { collectExpr(value, into: &out) }
        default: break
        }
    }
    // swiftlint:disable:next cyclomatic_complexity
    private func collectExpr(_ expr: AwkExpr, into out: inout Set<String>) {
        switch expr {
        case .getline(_, let file, _):
            if case .string(let str)? = file { out.insert(str) }
        case .binary(_, let lhs, let rhs):
            collectExpr(lhs, into: &out); collectExpr(rhs, into: &out)
        case .unary(_, let operand): collectExpr(operand, into: &out)
        case .ternary(let cond, let then, let alt):
            collectExpr(cond, into: &out); collectExpr(then, into: &out); collectExpr(alt, into: &out)
        case .call(_, let args):
            for arg in args { collectExpr(arg, into: &out) }
        case .assignment(_, _, let value): collectExpr(value, into: &out)
        case .field(let idx): collectExpr(idx, into: &out)
        case .arrayAccess(_, let key): collectExpr(key, into: &out)
        case .tuple(let elems): for elem in elems { collectExpr(elem, into: &out) }
        case .inExpr(let key, _): collectExpr(key, into: &out)
        default: break
        }
    }
}

private func processEscapes(_ str: String) -> String {
    str.replacingOccurrences(of: "\\t", with: "\t")
       .replacingOccurrences(of: "\\n", with: "\n")
       .replacingOccurrences(of: "\\r", with: "\r")
       .replacingOccurrences(of: "\\\\", with: "\\")
}
