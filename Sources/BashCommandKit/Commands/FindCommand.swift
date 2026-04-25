import BashInterpreter
import Foundation

/// `find [PATH...] [EXPRESSION]` — recursively walk one or more start
/// paths and apply an expression to every entry. With no `PATH`, walks
/// `.`. With no expression, every entry is printed.
///
/// ### Tests
/// - `-name PATTERN` — basename matches a shell glob
/// - `-iname PATTERN` — case-insensitive variant of `-name`
/// - `-path PATTERN` / `-wholename PATTERN` — full path matches a glob
/// - `-type [f|d|l]` — regular file, directory, or symlink
/// - `-empty` — empty regular files or empty directories
/// - `-newer FILE` — modified more recently than `FILE`
///
/// ### Actions
/// - `-print` — print the path with a newline (the default)
/// - `-print0` — print the path with a NUL terminator
/// - `-prune` — don't descend into matched directories
/// - `-delete` — delete the matched entry; implies `-depth`
/// - `-exec CMD … ;` — run `CMD …` once per match, replacing `{}`
/// - `-exec CMD … {} +` — batch matches and run `CMD …` once at the end
///
/// ### Operators
/// - `-not EXPR` / `! EXPR` — negation
/// - `EXPR1 -a EXPR2` / `EXPR1 -and EXPR2` / `EXPR1 EXPR2` — AND
/// - `EXPR1 -o EXPR2` / `EXPR1 -or EXPR2` — OR
/// - `( EXPR )` — grouping (each paren is its own argv token)
///
/// ### Global options (position-independent)
/// - `-maxdepth N` — only descend N levels (start path is depth 0)
/// - `-mindepth N` — skip entries shallower than N
/// - `-depth` — visit directory contents before the directory itself
///
/// Within each directory, entries are visited in sorted order so script
/// output and tests are deterministic.
///
/// Out of scope (need filesystem facts our `FileMetadata` doesn't carry):
/// `-perm`, `-xattr`, `-flags`, `-size`, `-mtime`. Symlink-following
/// global options (`-L` / `-H` / `-P`) are accepted as no-ops because
/// our metadata already follows symlinks via `stat(2)`.
public struct FindCommand: Command {
    public let name = "find"
    public init() {}

    public func run(_ argv: [String], shell: Shell) async throws -> ExitStatus {
        let parsed: Parsed
        do {
            parsed = try Self.parse(argv: Array(argv.dropFirst()))
        } catch let err as ParseError {
            shell.stderr("find: \(err.message)\n")
            return .failure
        }

        // Resolve `-newer FILE` paths to mtimes once before walking.
        var newerCache: [String: Date] = [:]
        for path in parsed.newerPaths {
            let resolved = shell.resolvePath(path)
            guard let meta = try? await shell.fileSystem.metadata(resolved)
            else {
                shell.stderr("find: \(path): no such file or directory\n")
                return .failure
            }
            newerCache[path] = meta.modifiedAt
        }

        let ctx = EvalContext(
            opts: parsed,
            newer: newerCache,
            shell: shell)

        var hadError = false
        for path in parsed.paths {
            let resolved = shell.resolvePath(path)
            do {
                try await walk(displayPath: path,
                               absolutePath: resolved,
                               depth: 0,
                               ctx: ctx)
            } catch {
                shell.stderr("find: \(path): \(error)\n")
                hadError = true
            }
        }

        // Flush any -exec ... + batches.
        for batch in parsed.batches {
            try await flushBatch(batch, shell: shell)
        }

        return hadError ? .failure : .success
    }

    // MARK: Walk

    private func walk(displayPath: String,
                      absolutePath: String,
                      depth: Int,
                      ctx: EvalContext) async throws {
        let meta: FileMetadata?
        do {
            meta = try await ctx.shell.fileSystem.metadata(absolutePath)
        } catch {
            if depth == 0 { throw error }
            ctx.shell.stderr("find: \(displayPath): \(error)\n")
            return
        }
        guard let meta else {
            if depth == 0 { throw FileSystemError.notFound(displayPath) }
            return
        }

        let depthOK = depth >= ctx.opts.minDepth
            && (ctx.opts.maxDepth.map { depth <= $0 } ?? true)

        // Pre-order: evaluate this node first, then descend.
        var pruned = false
        if !ctx.opts.depthFirst, depthOK {
            let r = try await evaluate(
                ctx.opts.expr,
                node: NodeInfo(displayPath: displayPath,
                               absolutePath: absolutePath,
                               meta: meta),
                ctx: ctx)
            pruned = r.pruned
        }

        let canDescend = !pruned
            && meta.kind == .directory
            && (ctx.opts.maxDepth.map { depth < $0 } ?? true)

        if canDescend {
            let entries: [String]
            do {
                entries = try await ctx.shell.fileSystem.list(absolutePath)
            } catch {
                ctx.shell.stderr("find: \(displayPath): \(error)\n")
                if ctx.opts.depthFirst, depthOK {
                    _ = try await evaluate(
                        ctx.opts.expr,
                        node: NodeInfo(displayPath: displayPath,
                                       absolutePath: absolutePath,
                                       meta: meta),
                        ctx: ctx)
                }
                return
            }
            for name in entries.sorted() {
                let childAbs = (absolutePath as NSString)
                    .appendingPathComponent(name)
                let childDisplay = Self.joinPath(displayPath, name)
                try await walk(displayPath: childDisplay,
                               absolutePath: childAbs,
                               depth: depth + 1,
                               ctx: ctx)
            }
        }

        // Post-order: evaluate this node *after* descending. `-prune` has
        // no effect here because we've already visited the children.
        if ctx.opts.depthFirst, depthOK {
            _ = try await evaluate(
                ctx.opts.expr,
                node: NodeInfo(displayPath: displayPath,
                               absolutePath: absolutePath,
                               meta: meta),
                ctx: ctx)
        }
    }

    // MARK: Expression evaluation

    /// Result of evaluating an expression for a single node.
    private struct EvalResult {
        var matched: Bool
        var pruned: Bool = false
    }

    private func evaluate(_ expr: Expr,
                          node: NodeInfo,
                          ctx: EvalContext) async throws -> EvalResult {
        switch expr {
        case .test(let p):
            let m = try await checkPredicate(p, node: node, ctx: ctx)
            return EvalResult(matched: m)
        case .action(let a):
            return try await runAction(a, node: node, ctx: ctx)
        case .not(let inner):
            let r = try await evaluate(inner, node: node, ctx: ctx)
            return EvalResult(matched: !r.matched, pruned: r.pruned)
        case .and(let l, let r):
            let lr = try await evaluate(l, node: node, ctx: ctx)
            // Short-circuit: don't evaluate the RHS if LHS is false.
            // Side-effecting actions on the RHS are intentionally
            // skipped, matching find's documented semantics.
            if !lr.matched { return lr }
            let rr = try await evaluate(r, node: node, ctx: ctx)
            return EvalResult(matched: rr.matched,
                              pruned: lr.pruned || rr.pruned)
        case .or(let l, let r):
            let lr = try await evaluate(l, node: node, ctx: ctx)
            if lr.matched { return lr }
            let rr = try await evaluate(r, node: node, ctx: ctx)
            return EvalResult(matched: rr.matched,
                              pruned: lr.pruned || rr.pruned)
        }
    }

    private func checkPredicate(_ p: Predicate,
                                node: NodeInfo,
                                ctx: EvalContext) async throws -> Bool {
        switch p {
        case .name(let pat, let ci):
            let base = (node.displayPath as NSString).lastPathComponent
            return Self.globMatch(pattern: pat, string: base,
                                  caseInsensitive: ci)
        case .path(let pat):
            return Self.globMatch(pattern: pat,
                                  string: node.displayPath)
        case .type(let t):
            switch t {
            case "f": return node.meta.kind == .file
            case "d": return node.meta.kind == .directory
            case "l": return node.meta.kind == .symlink
            default:  return false
            }
        case .empty:
            switch node.meta.kind {
            case .file:
                return node.meta.size == 0
            case .directory:
                let kids = (try? await ctx.shell.fileSystem
                    .list(node.absolutePath)) ?? []
                return kids.isEmpty
            default:
                return false
            }
        case .newer(let path):
            guard let ref = ctx.newer[path] else { return false }
            return node.meta.modifiedAt > ref
        }
    }

    private func runAction(_ a: Action,
                           node: NodeInfo,
                           ctx: EvalContext) async throws -> EvalResult {
        switch a {
        case .print:
            ctx.shell.stdout(node.displayPath + "\n")
            return EvalResult(matched: true)
        case .print0:
            ctx.shell.stdout(node.displayPath + "\u{0}")
            return EvalResult(matched: true)
        case .prune:
            // Returns true; the walker reads `pruned` to skip descent.
            // No effect under `-depth` (already descended) — matches
            // GNU find.
            return EvalResult(matched: true,
                              pruned: !ctx.opts.depthFirst)
        case .delete:
            // Skip deleting the start path (matches find's safety check).
            if node.displayPath == "." || node.displayPath == "/" {
                return EvalResult(matched: false)
            }
            do {
                try await ctx.shell.fileSystem.remove(
                    node.absolutePath, recursive: false)
                return EvalResult(matched: true)
            } catch {
                ctx.shell.stderr("find: -delete \(node.displayPath): \(error)\n")
                return EvalResult(matched: false)
            }
        case .execEach(let template):
            let argv = template.map { $0 == "{}" ? node.displayPath : $0 }
            let line = argv.map(Self.shellEscape).joined(separator: " ")
            do {
                let status = try await ctx.shell.run(line)
                return EvalResult(matched: status.isSuccess)
            } catch {
                ctx.shell.stderr("find: -exec: \(error)\n")
                return EvalResult(matched: false)
            }
        case .execBatch(let batch):
            batch.append(node.displayPath)
            // Per find: -exec ... + always evaluates true.
            return EvalResult(matched: true)
        }
    }

    /// Run an `-exec ... +` batch's accumulated paths and reset state.
    private func flushBatch(_ batch: ExecBatchState,
                            shell: Shell) async throws {
        let paths = batch.drain()
        guard !paths.isEmpty else { return }
        // Replace each `{}` token with the entire path list (each path
        // becomes its own argv element). Tokens that aren't `{}` pass
        // through unchanged.
        var argv: [String] = []
        for tok in batch.template {
            if tok == "{}" {
                argv.append(contentsOf: paths)
            } else {
                argv.append(tok)
            }
        }
        let line = argv.map(Self.shellEscape).joined(separator: " ")
        do {
            _ = try await shell.run(line)
        } catch {
            shell.stderr("find: -exec: \(error)\n")
        }
    }

    // MARK: Helpers

    static func joinPath(_ prefix: String, _ name: String) -> String {
        if prefix.isEmpty { return name }
        if prefix == "/" { return "/" + name }
        if prefix.hasSuffix("/") { return prefix + name }
        return prefix + "/" + name
    }

    /// POSIX shell-quote a string by wrapping in single quotes, with
    /// embedded single quotes encoded as `'\''`. Safe for arbitrary
    /// bytes-as-string content including spaces and shell metacharacters.
    static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Inner types

    private struct NodeInfo {
        let displayPath: String
        let absolutePath: String
        let meta: FileMetadata
    }

    private struct EvalContext {
        let opts: Parsed
        let newer: [String: Date]
        let shell: Shell
    }

    indirect enum Expr: Sendable {
        case test(Predicate)
        case action(Action)
        case not(Expr)
        case and(Expr, Expr)
        case or(Expr, Expr)
    }

    enum Predicate: Sendable {
        case name(String, caseInsensitive: Bool)
        case path(String)
        case type(Character)
        case empty
        /// Carries the *user-supplied* path; the runtime resolves it to
        /// an mtime via ``EvalContext/newer`` once before the walk.
        case newer(referencePath: String)
    }

    enum Action: Sendable {
        case print
        case print0
        case prune
        case delete
        case execEach([String])
        case execBatch(ExecBatchState)
    }

    /// Shared state for an `-exec ... +` batch — the parser holds a
    /// reference, the action enum holds the same reference, and the
    /// command's `run` flushes pending paths once the walk finishes.
    public final class ExecBatchState: @unchecked Sendable {
        let template: [String]
        private let lock = NSLock()
        private var pending: [String] = []

        init(template: [String]) {
            self.template = template
        }

        func append(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            pending.append(path)
        }

        func drain() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let out = pending
            pending = []
            return out
        }
    }

    struct Parsed: Sendable {
        var paths: [String]
        var maxDepth: Int?
        var minDepth: Int = 0
        var depthFirst: Bool = false
        var expr: Expr
        var batches: [ExecBatchState] = []
        var newerPaths: [String] = []
    }

    struct ParseError: Error {
        let message: String
    }

    // MARK: Parser
    //
    // Recursive-descent over argv with the precedence find requires:
    //
    //   expr        ::= or-expr
    //   or-expr     ::= and-expr ( ('-o' | '-or') and-expr )*
    //   and-expr    ::= not-expr ( ('-a' | '-and')? not-expr )*    (implicit AND)
    //   not-expr    ::= ('!' | '-not') not-expr | primary
    //   primary     ::= '(' expr ')' | TEST | ACTION
    //
    // Global options (`-maxdepth`, `-mindepth`, `-depth`) and the
    // symlink-following options (`-L`, `-l`, `-H`, `-P`) are stripped
    // out of the token stream up front; whatever remains is one
    // expression. The implicit `-print` is added at the end if no
    // side-effecting action appears in the parsed tree.

    static func parse(argv: [String]) throws -> Parsed {
        var paths: [String] = []
        var i = 0

        while i < argv.count {
            let a = argv[i]
            if Self.isExpressionToken(a) { break }
            paths.append(a)
            i += 1
        }
        if paths.isEmpty { paths = ["."] }

        var maxDepth: Int?
        var minDepth = 0
        var depthFirst = false
        var rest: [String] = []

        // Strip out global options. `-maxdepth N` etc. can appear
        // anywhere in the expression in our (lenient) grammar.
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "-maxdepth":
                guard i + 1 < argv.count, let n = Int(argv[i + 1]), n >= 0
                else {
                    throw ParseError(
                        message: "-maxdepth: expected non-negative integer")
                }
                maxDepth = n
                i += 2
            case "-mindepth":
                guard i + 1 < argv.count, let n = Int(argv[i + 1]), n >= 0
                else {
                    throw ParseError(
                        message: "-mindepth: expected non-negative integer")
                }
                minDepth = n
                i += 2
            case "-depth":
                depthFirst = true
                i += 1
            case "-L", "-H", "-P", "-l":
                // Symlink-following global options. Our metadata follows
                // symlinks already, so accept silently.
                i += 1
            default:
                rest.append(a)
                i += 1
            }
        }

        var batches: [ExecBatchState] = []
        var newerPaths: [String] = []

        let expr: Expr
        if rest.isEmpty {
            expr = .action(.print)
        } else {
            var parser = ExprParser(tokens: rest)
            let parsed = try parser.parseExpr()
            try parser.expectEnd()
            batches = parser.batches
            newerPaths = parser.newerPaths
            expr = Self.hasSideEffectAction(parsed)
                ? parsed
                : .and(parsed, .action(.print))
        }

        // `-delete` implies `-depth` (so children are deleted before
        // their parents — non-empty directory removal would otherwise
        // fail).
        if Self.containsDelete(expr) { depthFirst = true }

        return Parsed(paths: paths,
                      maxDepth: maxDepth,
                      minDepth: minDepth,
                      depthFirst: depthFirst,
                      expr: expr,
                      batches: batches,
                      newerPaths: newerPaths)
    }

    /// Treat a token as belonging to the expression part of argv when
    /// it starts with `-` or is one of the standalone operator tokens.
    private static func isExpressionToken(_ s: String) -> Bool {
        if s.hasPrefix("-") { return true }
        return s == "(" || s == ")" || s == "!"
    }

    private static func hasSideEffectAction(_ e: Expr) -> Bool {
        switch e {
        case .action(let a):
            switch a {
            case .print, .print0, .delete, .execEach, .execBatch: return true
            case .prune: return false
            }
        case .test: return false
        case .not(let i): return hasSideEffectAction(i)
        case .and(let l, let r), .or(let l, let r):
            return hasSideEffectAction(l) || hasSideEffectAction(r)
        }
    }

    private static func containsDelete(_ e: Expr) -> Bool {
        switch e {
        case .action(.delete): return true
        case .action: return false
        case .test: return false
        case .not(let i): return containsDelete(i)
        case .and(let l, let r), .or(let l, let r):
            return containsDelete(l) || containsDelete(r)
        }
    }

    private struct ExprParser {
        let tokens: [String]
        var i: Int = 0
        var batches: [ExecBatchState] = []
        var newerPaths: [String] = []

        var atEnd: Bool { i >= tokens.count }
        func peek() -> String? { i < tokens.count ? tokens[i] : nil }
        mutating func advance() -> String? {
            guard i < tokens.count else { return nil }
            let t = tokens[i]; i += 1; return t
        }

        mutating func expectEnd() throws {
            if let t = peek() {
                throw ParseError(message: "unexpected token: \(t)")
            }
        }

        mutating func parseExpr() throws -> Expr { try parseOr() }

        mutating func parseOr() throws -> Expr {
            var lhs = try parseAnd()
            while let t = peek(), t == "-o" || t == "-or" {
                _ = advance()
                let rhs = try parseAnd()
                lhs = .or(lhs, rhs)
            }
            return lhs
        }

        mutating func parseAnd() throws -> Expr {
            var lhs = try parseNot()
            while let t = peek() {
                if t == "-o" || t == "-or" || t == ")" { break }
                if t == "-a" || t == "-and" {
                    _ = advance()
                }
                let rhs = try parseNot()
                lhs = .and(lhs, rhs)
            }
            return lhs
        }

        mutating func parseNot() throws -> Expr {
            if let t = peek(), t == "!" || t == "-not" {
                _ = advance()
                let inner = try parseNot()
                return .not(inner)
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Expr {
            guard let t = advance() else {
                throw ParseError(message: "expected predicate")
            }
            if t == "(" {
                let e = try parseExpr()
                guard advance() == ")" else {
                    throw ParseError(message: "expected `)`")
                }
                return e
            }
            return try parseFlag(t)
        }

        mutating func value(for f: String) throws -> String {
            guard let v = advance() else {
                throw ParseError(message: "\(f): requires an argument")
            }
            return v
        }

        mutating func parseFlag(_ flag: String) throws -> Expr {
            switch flag {
            case "-name":
                let v = try value(for: flag)
                return .test(.name(v, caseInsensitive: false))
            case "-iname":
                let v = try value(for: flag)
                return .test(.name(v, caseInsensitive: true))
            case "-path", "-wholename":
                let v = try value(for: flag)
                return .test(.path(v))
            case "-type":
                let v = try value(for: flag)
                guard v.count == 1, let c = v.first, "fdl".contains(c) else {
                    throw ParseError(
                        message: "-type \(v): unknown type (use f, d, or l)")
                }
                return .test(.type(c))
            case "-empty":
                return .test(.empty)
            case "-newer":
                let v = try value(for: flag)
                newerPaths.append(v)
                return .test(.newer(referencePath: v))
            case "-print":
                return .action(.print)
            case "-print0":
                return .action(.print0)
            case "-prune":
                return .action(.prune)
            case "-delete":
                return .action(.delete)
            case "-exec":
                return try parseExec()
            default:
                throw ParseError(message: "unknown predicate: \(flag)")
            }
        }

        mutating func parseExec() throws -> Expr {
            var template: [String] = []
            while let t = advance() {
                if t == ";" { return .action(.execEach(template)) }
                if t == "+" {
                    let state = ExecBatchState(template: template)
                    batches.append(state)
                    return .action(.execBatch(state))
                }
                template.append(t)
            }
            throw ParseError(message: "-exec: missing terminator (`;` or `+`)")
        }
    }

    // MARK: Glob matching
    //
    // Inline `fnmatch`-style matcher: `*`, `?`, `[abc]`, `[a-z]`,
    // `[!abc]` / `[^abc]`, and `\x` escape. Mirrors
    // `BashInterpreter.GlobMatcher` (which is internal to that target).

    static func globMatch(pattern: String,
                          string: String,
                          caseInsensitive: Bool = false) -> Bool {
        let p = Array(caseInsensitive ? pattern.lowercased() : pattern)
        let s = Array(caseInsensitive ? string.lowercased() : string)
        return globMatch(p, 0, s, 0)
    }

    private static func globMatch(_ p: [Character], _ pi: Int,
                                  _ s: [Character], _ si: Int) -> Bool {
        var pi = pi
        var si = si
        while pi < p.count {
            let c = p[pi]
            switch c {
            case "*":
                while pi < p.count, p[pi] == "*" { pi += 1 }
                if pi == p.count { return true }
                var k = si
                while k <= s.count {
                    if globMatch(p, pi, s, k) { return true }
                    k += 1
                }
                return false
            case "?":
                if si >= s.count { return false }
                pi += 1
                si += 1
            case "[":
                if si >= s.count { return false }
                guard let (matched, end) = charClass(p, pi, s[si])
                else { return false }
                if !matched { return false }
                pi = end
                si += 1
            case "\\":
                guard pi + 1 < p.count, si < s.count,
                      p[pi + 1] == s[si]
                else { return false }
                pi += 2
                si += 1
            default:
                if si >= s.count || s[si] != c { return false }
                pi += 1
                si += 1
            }
        }
        return si == s.count
    }

    private static func charClass(_ p: [Character], _ pi: Int,
                                  _ c: Character) -> (Bool, Int)? {
        var i = pi + 1
        guard i < p.count else { return nil }
        var negate = false
        if p[i] == "!" || p[i] == "^" {
            negate = true
            i += 1
        }
        var matched = false
        var first = true
        while i < p.count, !(p[i] == "]" && !first) {
            first = false
            let start = p[i]
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                let end = p[i + 2]
                if c >= start && c <= end { matched = true }
                i += 3
            } else {
                if c == start { matched = true }
                i += 1
            }
        }
        guard i < p.count, p[i] == "]" else { return nil }
        return (matched != negate, i + 1)
    }
}
