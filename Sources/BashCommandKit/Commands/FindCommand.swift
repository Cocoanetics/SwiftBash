// swiftlint:disable file_length
// Single-file find implementation — walk + parse + glob.
// Splitting would scatter the closely-coupled Expr / Predicate /
// Action types and their parser.
import BashInterpreter
import Foundation

// `find [PATH...] [EXPRESSION]` — recursively walk one or more start
// paths and apply an expression to every entry. With no `PATH`, walks
// `.`. With no expression, every entry is printed.
//
// ### Tests
// - `-name PATTERN` — basename matches a shell glob
// - `-iname PATTERN` — case-insensitive variant of `-name`
// - `-path PATTERN` / `-wholename PATTERN` — full path matches a glob
// - `-regex PATTERN` / `-iregex PATTERN` — full path matches a regex
// - `-type [f|d|l]` — regular file, directory, or symlink
// - `-empty` — empty regular files or empty directories
// - `-newer FILE` — modified more recently than `FILE`
// - `-mtime [+-]N` — modified N×24h ago (`+N` strictly more, `-N` less)
// - `-mmin [+-]N` — modified N minutes ago
// - `-size [+-]N[ckMG]` — size matches (default unit blocks of 512B,
//   `c` bytes, `k` KiB, `M` MiB, `G` GiB)
// - `-perm MODE` — permission bits (octal). `-MODE` requires all bits
//   set; `/MODE` requires any bit set; bare `MODE` is exact match.
//
// ### Actions
// - `-print` — print the path with a newline (the default)
// - `-print0` — print the path with a NUL terminator
// - `-prune` — don't descend into matched directories
// - `-delete` — delete the matched entry; implies `-depth`
// - `-exec CMD … ;` — run `CMD …` once per match, replacing `{}`
// - `-exec CMD … {} +` — batch matches and run `CMD …` once at the end
//
// ### Operators
// - `-not EXPR` / `! EXPR` — negation
// - `EXPR1 -a EXPR2` / `EXPR1 -and EXPR2` / `EXPR1 EXPR2` — AND
// - `EXPR1 -o EXPR2` / `EXPR1 -or EXPR2` — OR
// - `( EXPR )` — grouping (each paren is its own argv token)
//
// ### Global options (position-independent)
// - `-maxdepth N` — only descend N levels (start path is depth 0)
// - `-mindepth N` — skip entries shallower than N
// - `-depth` — visit directory contents before the directory itself
//
// Within each directory, entries are visited in sorted order so script
// output and tests are deterministic.
//
// Out of scope: `-xattr`, `-flags`, `-uid`, `-gid`. Symlink-following
// global options (`-L` / `-H` / `-P`) are accepted as no-ops because
// our metadata already follows symlinks via `stat(2)`. `-perm` reads
// the mode via `stat(2)` directly since `FileMetadata` doesn't carry
// permission bits.
// swiftlint:disable:next type_body_length
public struct FindCommand: Command {
    public let name = "find"
    public init() {}

    public func run(_ argv: [String]) async throws -> ExitStatus {
        if argv.dropFirst().contains("--version") {
            Shell.bashCurrent.stdout("find (SwiftBash) \(SwiftBashVersion.packageVersion)\n")
            return .success
        }
        let parsed: Parsed
        do {
            parsed = try Self.parse(argv: Array(argv.dropFirst()))
        } catch let err as ParseError {
            Shell.bashCurrent.stderr("find: \(err.message)\n")
            return .failure
        }

        // Resolve `-newer FILE` paths to mtimes once before walking.
        var newerCache: [String: Date] = [:]
        for path in parsed.newerPaths {
            let resolved = Shell.bashCurrent.resolvePath(path)
            guard let meta = try? await Shell.bashCurrent.fileSystem.metadata(resolved)
            else {
                Shell.bashCurrent.stderr("find: \(path): no such file or directory\n")
                return .failure
            }
            newerCache[path] = meta.modifiedAt
        }

        let ctx = EvalContext(
            opts: parsed,
            newer: newerCache)

        var hadError = false
        for path in parsed.paths {
            let resolved = Shell.bashCurrent.resolvePath(path)
            do {
                try await walk(displayPath: path,
                               absolutePath: resolved,
                               depth: 0,
                               ctx: ctx)
            } catch {
                Shell.bashCurrent.stderr("find: \(path): \(error)\n")
                hadError = true
            }
        }

        // Flush any -exec ... + batches.
        for batch in parsed.batches {
            try await flushBatch(batch)
        }

        return hadError ? .failure : .success
    }

    // MARK: Walk

    private func walk(displayPath: String,
                      absolutePath: String,
                      depth: Int,
                      ctx: EvalContext) async throws {
        // Per-entry cancellation check — `find /` against a huge tree
        // becomes interruptible.
        try Task.checkCancellation()
        guard let meta = try await resolveMeta(
            displayPath: displayPath,
            absolutePath: absolutePath,
            depth: depth)
        else { return }

        let depthOK = depth >= ctx.opts.minDepth
            && (ctx.opts.maxDepth.map { depth <= $0 } ?? true)
        let node = NodeInfo(displayPath: displayPath,
                            absolutePath: absolutePath,
                            meta: meta)

        // Pre-order: evaluate this node first, then descend.
        var pruned = false
        if !ctx.opts.depthFirst, depthOK {
            let result = try await evaluate(ctx.opts.expr, node: node, ctx: ctx)
            pruned = result.pruned
        }

        let canDescend = !pruned
            && meta.kind == .directory
            && (ctx.opts.maxDepth.map { depth < $0 } ?? true)
        if canDescend {
            try await descend(node: node, depth: depth, ctx: ctx, depthOK: depthOK)
        }

        // Post-order: evaluate this node *after* descending. `-prune` has
        // no effect here because we've already visited the children.
        if ctx.opts.depthFirst, depthOK {
            _ = try await evaluate(ctx.opts.expr, node: node, ctx: ctx)
        }
    }

    private func resolveMeta(displayPath: String,
                             absolutePath: String,
                             depth: Int) async throws -> FileMetadata? {
        let meta: FileMetadata?
        do {
            meta = try await Shell.bashCurrent.fileSystem.metadata(absolutePath)
        } catch {
            if depth == 0 { throw error }
            Shell.bashCurrent.stderr("find: \(displayPath): \(error)\n")
            return nil
        }
        guard let meta else {
            if depth == 0 { throw FileSystemError.notFound(displayPath) }
            return nil
        }
        return meta
    }

    private func descend(node: NodeInfo, depth: Int,
                         ctx: EvalContext, depthOK: Bool) async throws {
        let entries: [String]
        do {
            entries = try await Shell.bashCurrent.fileSystem
                .list(node.absolutePath).map(\.name)
        } catch {
            Shell.bashCurrent.stderr("find: \(node.displayPath): \(error)\n")
            if ctx.opts.depthFirst, depthOK {
                _ = try await evaluate(ctx.opts.expr, node: node, ctx: ctx)
            }
            return
        }
        for name in entries.sorted() {
            let childAbs = (node.absolutePath as NSString)
                .appendingPathComponent(name)
            let childDisplay = Self.joinPath(node.displayPath, name)
            try await walk(displayPath: childDisplay,
                           absolutePath: childAbs,
                           depth: depth + 1,
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
        case .test(let predicate):
            let matched = try await checkPredicate(predicate, node: node, ctx: ctx)
            return EvalResult(matched: matched)
        case .action(let action):
            return try await runAction(action, node: node, ctx: ctx)
        case .not(let inner):
            let inner = try await evaluate(inner, node: node, ctx: ctx)
            return EvalResult(matched: !inner.matched, pruned: inner.pruned)
        case .and(let left, let right):
            let leftResult = try await evaluate(left, node: node, ctx: ctx)
            // Short-circuit: don't evaluate the RHS if LHS is false.
            // Side-effecting actions on the RHS are intentionally
            // skipped, matching find's documented semantics.
            if !leftResult.matched { return leftResult }
            let rightResult = try await evaluate(right, node: node, ctx: ctx)
            return EvalResult(matched: rightResult.matched,
                              pruned: leftResult.pruned || rightResult.pruned)
        case .or(let left, let right):
            let leftResult = try await evaluate(left, node: node, ctx: ctx)
            if leftResult.matched { return leftResult }
            let rightResult = try await evaluate(right, node: node, ctx: ctx)
            return EvalResult(matched: rightResult.matched,
                              pruned: leftResult.pruned || rightResult.pruned)
        }
    }

    // Predicate switch covers 10 distinct find tests; splitting into
    // a helper per case would obscure the table of behaviours.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func checkPredicate(_ predicate: Predicate,
                                node: NodeInfo,
                                ctx: EvalContext) async throws -> Bool {
        switch predicate {
        case .name(let pattern, let caseInsens):
            let base = (node.displayPath as NSString).lastPathComponent
            return Self.globMatch(pattern: pattern, string: base,
                                  caseInsensitive: caseInsens)
        case .path(let pattern):
            return Self.globMatch(pattern: pattern,
                                  string: node.displayPath)
        case .type(let typeChar):
            switch typeChar {
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
                let kids = (try? await Shell.bashCurrent.fileSystem
                    .list(node.absolutePath)) ?? []
                return kids.isEmpty
            default:
                return false
            }
        case .newer(let path):
            guard let referenceMtime = ctx.newer[path] else { return false }
            return node.meta.modifiedAt > referenceMtime
        case .regex(let pattern, let caseInsens):
            var opts: NSRegularExpression.Options = []
            if caseInsens { opts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: opts) else {
                return false
            }
            let nsPath = node.displayPath as NSString
            return regex.firstMatch(
                in: node.displayPath,
                range: NSRange(location: 0, length: nsPath.length)) != nil
        case .mtime(let days, let cmp):
            let secsAgo = Date().timeIntervalSince(node.meta.modifiedAt)
            let buckets = Int(secsAgo / (24 * 60 * 60))
            return Self.compareInt(buckets, days, cmp)
        case .mmin(let mins, let cmp):
            let secsAgo = Date().timeIntervalSince(node.meta.modifiedAt)
            let buckets = Int(secsAgo / 60)
            return Self.compareInt(buckets, mins, cmp)
        case .size(let value, let unit, let cmp):
            // Round up to the nearest unit, GNU/POSIX style.
            let raw = Double(node.meta.size) / Double(unit.multiplier)
            let buckets: Int64 = unit == .bytes
                ? node.meta.size
                : Int64(raw.rounded(.up))
            return Self.compareInt64(buckets, value, cmp)
        case .perm(let want, let match):
            // Read permission bits via FileMetadata so this works with
            // any FileSystem backing, not just the real disk.
            let masked = node.meta.mode & 0o7777
            switch match {
            case .exact: return masked == want
            case .all:   return (masked & want) == want
            case .any:   return want == 0 ? false : (masked & want) != 0
            }
        }
    }

    static func compareInt(_ have: Int, _ want: Int, _ cmp: Comparison) -> Bool {
        switch cmp {
        case .exact: return have == want
        case .more: return have > want
        case .less: return have < want
        }
    }
    static func compareInt64(_ have: Int64, _ want: Int64, _ cmp: Comparison) -> Bool {
        switch cmp {
        case .exact: return have == want
        case .more: return have > want
        case .less: return have < want
        }
    }

    private func runAction(_ action: Action,
                           node: NodeInfo,
                           ctx: EvalContext) async throws -> EvalResult {
        switch action {
        case .print:
            Shell.bashCurrent.stdout(node.displayPath + "\n")
            return EvalResult(matched: true)
        case .print0:
            Shell.bashCurrent.stdout(node.displayPath + "\u{0}")
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
                try await Shell.bashCurrent.fileSystem.remove(
                    node.absolutePath, recursive: false)
                return EvalResult(matched: true)
            } catch {
                Shell.bashCurrent.stderr("find: -delete \(node.displayPath): \(error)\n")
                return EvalResult(matched: false)
            }
        case .execEach(let template):
            let argv = template.map { $0 == "{}" ? node.displayPath : $0 }
            let line = argv.map(Self.shellEscape).joined(separator: " ")
            do {
                let status = try await Shell.bashCurrent.run(line)
                return EvalResult(matched: status.isSuccess)
            } catch {
                Shell.bashCurrent.stderr("find: -exec: \(error)\n")
                return EvalResult(matched: false)
            }
        case .execBatch(let batch):
            batch.append(node.displayPath)
            // Per find: -exec ... + always evaluates true.
            return EvalResult(matched: true)
        }
    }

    /// Run an `-exec ... +` batch's accumulated paths and reset state.
    private func flushBatch(_ batch: ExecBatchState) async throws {
        let paths = batch.drain()
        guard !paths.isEmpty else { return }
        // Replace each `{}` token with the entire path list (each path
        // becomes its own argv element). Tokens that aren't `{}` pass
        // through unchanged.
        var argv: [String] = []
        for token in batch.template {
            if token == "{}" {
                argv.append(contentsOf: paths)
            } else {
                argv.append(token)
            }
        }
        let line = argv.map(Self.shellEscape).joined(separator: " ")
        do {
            _ = try await Shell.bashCurrent.run(line)
        } catch {
            Shell.bashCurrent.stderr("find: -exec: \(error)\n")
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
    static func shellEscape(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    }

    indirect enum Expr: Sendable {
        case test(Predicate)
        case action(Action)
        case not(Expr)
        case and(Expr, Expr)
        // Boolean operator from find(1); name mirrors `-or`/`-o`.
        // swiftlint:disable:next identifier_name
        case or(Expr, Expr)
    }

    enum Predicate: Sendable {
        case name(String, caseInsensitive: Bool)
        case path(String)
        case regex(String, caseInsensitive: Bool)
        case type(Character)
        case empty
        /// Carries the *user-supplied* path; the runtime resolves it to
        /// an mtime via ``EvalContext/newer`` once before the walk.
        case newer(referencePath: String)
        /// `mtime [+-]N` — N×24h ago. `+N` strictly older, `-N` newer.
        case mtime(days: Int, comparison: Comparison)
        /// `mmin [+-]N` — N minutes ago.
        case mmin(minutes: Int, comparison: Comparison)
        /// `size [+-]N[ckMG]` — `c` bytes, `k` KiB, `M` MiB, `G` GiB,
        /// none → 512-byte blocks.
        case size(value: Int64, unit: SizeUnit, comparison: Comparison)
        /// `perm MODE` (octal). `-MODE` requires all bits set;
        /// `/MODE` requires any bit set; bare MODE is exact.
        case perm(mode: UInt16, match: PermMatch)
    }

    enum Comparison: Sendable {
        case exact, more, less   // N, +N, -N respectively
    }

    enum SizeUnit: Sendable {
        case blocks, bytes, kib, mib, gib
        var multiplier: Int64 {
            switch self {
            case .blocks: return 512
            case .bytes:  return 1
            case .kib:    return 1024
            case .mib:    return 1024 * 1024
            case .gib:    return 1024 * 1024 * 1024
            }
        }
    }

    enum PermMatch: Sendable {
        case exact, all, any
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
        var state = GlobalOptionsState()

        while state.index < argv.count {
            let arg = argv[state.index]
            if Self.isExpressionToken(arg) { break }
            paths.append(arg)
            state.index += 1
        }
        if paths.isEmpty { paths = ["."] }

        try parseGlobalOptions(argv: argv, state: &state)
        let rest = state.rest

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
        if Self.containsDelete(expr) { state.depthFirst = true }

        return Parsed(paths: paths,
                      maxDepth: state.maxDepth,
                      minDepth: state.minDepth,
                      depthFirst: state.depthFirst,
                      expr: expr,
                      batches: batches,
                      newerPaths: newerPaths)
    }

    private struct GlobalOptionsState {
        var index: Int = 0
        var rest: [String] = []
        var maxDepth: Int?
        var minDepth: Int = 0
        var depthFirst: Bool = false
    }

    /// Strip the global options (`-maxdepth`, `-mindepth`, `-depth`)
    /// and the symlink-following flags out of `argv`, leaving the
    /// remaining tokens for the expression parser.
    private static func parseGlobalOptions(argv: [String],
                                           state: inout GlobalOptionsState) throws {
        while state.index < argv.count {
            let arg = argv[state.index]
            switch arg {
            case "-maxdepth":
                guard state.index + 1 < argv.count,
                      let value = Int(argv[state.index + 1]),
                      value >= 0
                else {
                    throw ParseError(
                        message: "-maxdepth: expected non-negative integer")
                }
                state.maxDepth = value
                state.index += 2
            case "-mindepth":
                guard state.index + 1 < argv.count,
                      let value = Int(argv[state.index + 1]),
                      value >= 0
                else {
                    throw ParseError(
                        message: "-mindepth: expected non-negative integer")
                }
                state.minDepth = value
                state.index += 2
            case "-depth":
                state.depthFirst = true
                state.index += 1
            case "-L", "-H", "-P", "-l":
                // Symlink-following global options. Our metadata follows
                // symlinks already, so accept silently.
                state.index += 1
            default:
                state.rest.append(arg)
                state.index += 1
            }
        }
    }

    /// Treat a token as belonging to the expression part of argv when
    /// it starts with `-` or is one of the standalone operator tokens.
    private static func isExpressionToken(_ token: String) -> Bool {
        if token.hasPrefix("-") { return true }
        return token == "(" || token == ")" || token == "!"
    }

    private static func hasSideEffectAction(_ expr: Expr) -> Bool {
        switch expr {
        case .action(let action):
            switch action {
            case .print, .print0, .delete, .execEach, .execBatch: return true
            case .prune: return false
            }
        case .test: return false
        case .not(let inner): return hasSideEffectAction(inner)
        case .and(let left, let right), .or(let left, let right):
            return hasSideEffectAction(left) || hasSideEffectAction(right)
        }
    }

    private static func containsDelete(_ expr: Expr) -> Bool {
        switch expr {
        case .action(.delete): return true
        case .action: return false
        case .test: return false
        case .not(let inner): return containsDelete(inner)
        case .and(let left, let right), .or(let left, let right):
            return containsDelete(left) || containsDelete(right)
        }
    }

    private struct ExprParser {
        let tokens: [String]
        var index: Int = 0
        var batches: [ExecBatchState] = []
        var newerPaths: [String] = []

        var atEnd: Bool { index >= tokens.count }
        func peek() -> String? { index < tokens.count ? tokens[index] : nil }
        mutating func advance() -> String? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            index += 1
            return token
        }

        mutating func expectEnd() throws {
            if let token = peek() {
                throw ParseError(message: "unexpected token: \(token)")
            }
        }

        mutating func parseExpr() throws -> Expr { try parseOr() }

        mutating func parseOr() throws -> Expr {
            var lhs = try parseAnd()
            while let token = peek(), token == "-o" || token == "-or" {
                _ = advance()
                let rhs = try parseAnd()
                lhs = .or(lhs, rhs)
            }
            return lhs
        }

        mutating func parseAnd() throws -> Expr {
            var lhs = try parseNot()
            while let token = peek() {
                if token == "-o" || token == "-or" || token == ")" { break }
                if token == "-a" || token == "-and" {
                    _ = advance()
                }
                let rhs = try parseNot()
                lhs = .and(lhs, rhs)
            }
            return lhs
        }

        mutating func parseNot() throws -> Expr {
            if let token = peek(), token == "!" || token == "-not" {
                _ = advance()
                let inner = try parseNot()
                return .not(inner)
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Expr {
            guard let token = advance() else {
                throw ParseError(message: "expected predicate")
            }
            if token == "(" {
                let expr = try parseExpr()
                guard advance() == ")" else {
                    throw ParseError(message: "expected `)`")
                }
                return expr
            }
            return try parseFlag(token)
        }

        mutating func value(for flag: String) throws -> String {
            guard let value = advance() else {
                throw ParseError(message: "\(flag): requires an argument")
            }
            return value
        }

        // Maps every supported find predicate / action keyword.
        // swiftlint:disable:next cyclomatic_complexity function_body_length
        mutating func parseFlag(_ flag: String) throws -> Expr {
            switch flag {
            case "-name":
                let arg = try value(for: flag)
                return .test(.name(arg, caseInsensitive: false))
            case "-iname":
                let arg = try value(for: flag)
                return .test(.name(arg, caseInsensitive: true))
            case "-path", "-wholename":
                let arg = try value(for: flag)
                return .test(.path(arg))
            case "-type":
                let arg = try value(for: flag)
                guard arg.count == 1,
                      let char = arg.first,
                      "fdl".contains(char) else {
                    throw ParseError(
                        message: "-type \(arg): unknown type (use f, d, or l)")
                }
                return .test(.type(char))
            case "-empty":
                return .test(.empty)
            case "-newer":
                let arg = try value(for: flag)
                newerPaths.append(arg)
                return .test(.newer(referencePath: arg))
            case "-regex":
                return .test(.regex(try value(for: flag), caseInsensitive: false))
            case "-iregex":
                return .test(.regex(try value(for: flag), caseInsensitive: true))
            case "-mtime":
                let parsed = try FindCommand.parseSignedInt(
                    try value(for: flag), label: flag)
                return .test(.mtime(
                    days: parsed.value, comparison: parsed.comparison))
            case "-mmin":
                let parsed = try FindCommand.parseSignedInt(
                    try value(for: flag), label: flag)
                return .test(.mmin(
                    minutes: parsed.value, comparison: parsed.comparison))
            case "-size":
                let parsed = try FindCommand.parseSize(try value(for: flag))
                return .test(.size(
                    value: parsed.value, unit: parsed.unit,
                    comparison: parsed.comparison))
            case "-perm":
                let parsed = try FindCommand.parsePerm(try value(for: flag))
                return .test(.perm(mode: parsed.mode, match: parsed.match))
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
            while let token = advance() {
                if token == ";" { return .action(.execEach(template)) }
                if token == "+" {
                    let state = ExecBatchState(template: template)
                    batches.append(state)
                    return .action(.execBatch(state))
                }
                template.append(token)
            }
            throw ParseError(message: "-exec: missing terminator (`;` or `+`)")
        }
    }

    // MARK: Argument parsers

    struct SignedIntResult {
        let value: Int
        let comparison: Comparison
    }

    struct SizeResult {
        let value: Int64
        let unit: SizeUnit
        let comparison: Comparison
    }

    struct PermResult {
        let mode: UInt16
        let match: PermMatch
    }

    /// Parse `[+-]N` for `-mtime` / `-mmin`.
    static func parseSignedInt(_ raw: String, label: String) throws -> SignedIntResult {
        var rest = raw
        var cmp: Comparison = .exact
        if rest.first == "+" {
            cmp = .more
            rest.removeFirst()
        } else if rest.first == "-" {
            cmp = .less
            rest.removeFirst()
        }
        guard let value = Int(rest) else {
            throw ParseError(message: "\(label): expected an integer, got \(raw)")
        }
        return SignedIntResult(value: value, comparison: cmp)
    }

    /// Parse `[+-]N[ckMG]` for `-size`. Default unit is 512-byte
    /// blocks (POSIX).
    static func parseSize(_ raw: String) throws -> SizeResult {
        var rest = raw
        var cmp: Comparison = .exact
        if rest.first == "+" {
            cmp = .more
            rest.removeFirst()
        } else if rest.first == "-" {
            cmp = .less
            rest.removeFirst()
        }
        var unit: SizeUnit = .blocks
        if let last = rest.last {
            switch last {
            case "c": unit = .bytes;  rest.removeLast()
            case "k": unit = .kib;    rest.removeLast()
            case "M": unit = .mib;    rest.removeLast()
            case "G": unit = .gib;    rest.removeLast()
            case "b": unit = .blocks; rest.removeLast()
            default: break
            }
        }
        guard let value = Int64(rest) else {
            throw ParseError(message: "-size: bad value: \(raw)")
        }
        return SizeResult(value: value, unit: unit, comparison: cmp)
    }

    /// Parse the `-perm` argument: leading `-` or `/` selects all/any
    /// match; otherwise exact. Octal only.
    static func parsePerm(_ raw: String) throws -> PermResult {
        var rest = raw
        var match: PermMatch = .exact
        if rest.first == "-" {
            match = .all
            rest.removeFirst()
        } else if rest.first == "/" {
            match = .any
            rest.removeFirst()
        }
        guard let mode = UInt16(rest, radix: 8) else {
            throw ParseError(message: "-perm: bad mode: \(raw)")
        }
        return PermResult(mode: mode, match: match)
    }

    // MARK: Glob matching
    //
    // Inline `fnmatch`-style matcher: `*`, `?`, `[abc]`, `[a-z]`,
    // `[!abc]` / `[^abc]`, and `\x` escape. Mirrors
    // `BashInterpreter.GlobMatcher` (which is internal to that target).

    static func globMatch(pattern: String,
                          string: String,
                          caseInsensitive: Bool = false) -> Bool {
        let patChars = Array(caseInsensitive ? pattern.lowercased() : pattern)
        let strChars = Array(caseInsensitive ? string.lowercased() : string)
        return globMatch(patChars, 0, strChars, 0)
    }

    // Single inline glob matcher; per-case helpers would balloon
    // the recursion / state-passing.
    // swiftlint:disable:next cyclomatic_complexity
    private static func globMatch(_ pattern: [Character], _ startPI: Int,
                                  _ string: [Character], _ startSI: Int) -> Bool {
        var patIdx = startPI
        var strIdx = startSI
        while patIdx < pattern.count {
            let char = pattern[patIdx]
            switch char {
            case "*":
                while patIdx < pattern.count, pattern[patIdx] == "*" { patIdx += 1 }
                if patIdx == pattern.count { return true }
                var probe = strIdx
                while probe <= string.count {
                    if globMatch(pattern, patIdx, string, probe) { return true }
                    probe += 1
                }
                return false
            case "?":
                if strIdx >= string.count { return false }
                patIdx += 1
                strIdx += 1
            case "[":
                if strIdx >= string.count { return false }
                guard let result = charClass(pattern, patIdx, string[strIdx])
                else { return false }
                if !result.matched { return false }
                patIdx = result.end
                strIdx += 1
            case "\\":
                guard patIdx + 1 < pattern.count, strIdx < string.count,
                      pattern[patIdx + 1] == string[strIdx]
                else { return false }
                patIdx += 2
                strIdx += 1
            default:
                if strIdx >= string.count || string[strIdx] != char { return false }
                patIdx += 1
                strIdx += 1
            }
        }
        return strIdx == string.count
    }

    private struct CharClassMatch {
        let matched: Bool
        let end: Int
    }

    private static func charClass(_ pattern: [Character], _ startPI: Int,
                                  _ char: Character) -> CharClassMatch? {
        var index = startPI + 1
        guard index < pattern.count else { return nil }
        var negate = false
        if pattern[index] == "!" || pattern[index] == "^" {
            negate = true
            index += 1
        }
        var matched = false
        var first = true
        while index < pattern.count, !(pattern[index] == "]" && !first) {
            first = false
            let start = pattern[index]
            if index + 2 < pattern.count,
               pattern[index + 1] == "-",
               pattern[index + 2] != "]" {
                let end = pattern[index + 2]
                if char >= start && char <= end { matched = true }
                index += 3
            } else {
                if char == start { matched = true }
                index += 1
            }
        }
        guard index < pattern.count, pattern[index] == "]" else { return nil }
        return CharClassMatch(matched: matched != negate, end: index + 1)
    }
}
