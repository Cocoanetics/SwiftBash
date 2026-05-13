import Foundation

/// `test EXPR` and `[ EXPR ]` — evaluate a conditional expression.
/// Return `.success` (exit 0) if the expression is true,
/// `.failure` (exit 1) if false. A malformed expression produces
/// exit 2 with a diagnostic on stderr.
///
/// This is the POSIX `test` builtin, supporting:
/// - **File ops**: `-e`, `-f`, `-d`, `-s`, `-r`, `-w`, `-x`, `-L`,
///   `-h`, `-nt`, `-ot`, `-ef`.
/// - **String ops**: `-z`, `-n`, `=`, `==`, `!=`, `<`, `>`.
/// - **Integer ops**: `-eq`, `-ne`, `-lt`, `-le`, `-gt`, `-ge`.
/// - **Logical**: `!`, `-a`, `-o`, parentheses.
///
/// File ops route through ``Shell/fileSystem`` so they work against
/// `RealFileSystem`, `InMemoryFileSystem`, or any custom backend.
public struct TestCommand: Command {
    public let name: String
    public init(name: String = "test") { self.name = name }

    public func run(_ argv: [String]) async throws -> ExitStatus {
        var args = Array(argv.dropFirst())

        // `[ EXPR ]` requires a literal `]` as the final arg.
        if argv.first == "[" {
            guard args.last == "]" else {
                Shell.bashCurrent.stderr("[: missing `]'\n")
                return ExitStatus(2)
            }
            args.removeLast()
        }

        do {
            var parser = TestExpressionParser(tokens: args)
            let result = try await parser.parse()
            return result ? .success : .failure
        } catch let err as TestError {
            Shell.bashCurrent.stderr("\(name): \(err.message)\n")
            return ExitStatus(2)
        }
    }
}

// MARK: Errors

private struct TestError: Error {
    let message: String
}

// MARK: Expression parser

/// Recursive-descent parser/evaluator over the POSIX-style argument
/// list. Grammar:
/// ```
/// expr := orExpr
/// orExpr  := andExpr ('-o' andExpr)*
/// andExpr := notExpr ('-a' notExpr)*
/// notExpr := '!' notExpr | primary
/// primary := '(' expr ')' | unary | binary | nullary
/// ```
private struct TestExpressionParser {
    let tokens: [String]
    var pos: Int = 0

    init(tokens: [String]) { self.tokens = tokens }

    private mutating func peek() -> String? {
        pos < tokens.count ? tokens[pos] : nil
    }
    private mutating func advance() -> String? {
        guard pos < tokens.count else { return nil }
        let t = tokens[pos]
        pos += 1
        return t
    }
    private var remaining: Int { tokens.count - pos }

    mutating func parse() async throws -> Bool {
        // Empty argument list — `test` (no args) is false.
        if tokens.isEmpty { return false }
        let result = try await parseOr()
        if pos != tokens.count {
            throw TestError(message:
                "unexpected argument: `\(tokens[pos])'")
        }
        return result
    }

    private mutating func parseOr() async throws -> Bool {
        var left = try await parseAnd()
        while peek() == "-o" {
            _ = advance()
            let right = try await parseAnd()
            left = left || right
        }
        return left
    }

    private mutating func parseAnd() async throws -> Bool {
        var left = try await parseNot()
        while peek() == "-a" {
            _ = advance()
            let right = try await parseNot()
            left = left && right
        }
        return left
    }

    private mutating func parseNot() async throws -> Bool {
        if peek() == "!" {
            _ = advance()
            return !(try await parseNot())
        }
        return try await parsePrimary()
    }

    private mutating func parsePrimary() async throws -> Bool {
        // Parenthesised group.
        if peek() == "(" {
            _ = advance()
            let inner = try await parseOr()
            guard advance() == ")" else {
                throw TestError(message: "missing `)'")
            }
            return inner
        }

        // Lookahead to decide unary vs. binary vs. nullary. POSIX rule
        // is: if 3 args remain and the middle one is a binary op, do
        // a binary. If 2 remain and the first is a unary op, do unary.
        // Otherwise the lone arg is "true if non-empty".
        if remaining >= 3,
           let mid = tokens[safe: pos + 1],
           Self.binaryOps.contains(mid)
        {
            let lhs = advance()!
            let op = advance()!
            let rhs = advance()!
            return try await evalBinary(
                lhs: lhs, op: op, rhs: rhs)
        }
        if remaining >= 2,
           let first = peek(),
           Self.unaryOps.contains(first)
        {
            let op = advance()!
            let arg = advance()!
            return try await evalUnary(op: op, arg: arg)
        }
        // Nullary: a single arg is "true if non-empty".
        guard let arg = advance() else {
            throw TestError(message: "missing argument")
        }
        return !arg.isEmpty
    }

    // MARK: Operator tables

    private static let unaryOps: Set<String> = [
        "-e", "-f", "-d", "-s", "-r", "-w", "-x",
        "-L", "-h", "-z", "-n", "-b", "-c", "-p", "-S", "-t", "-g", "-u", "-k"
    ]
    private static let binaryOps: Set<String> = [
        "=", "==", "!=", "<", ">",
        "-eq", "-ne", "-lt", "-le", "-gt", "-ge",
        "-nt", "-ot", "-ef"
    ]

    // MARK: Unary evaluation

    private func evalUnary(op: String, arg: String) async throws -> Bool
    {
        let path = Shell.bashCurrent.resolvePath(arg)
        switch op {
        case "-e":
            return (try? await Shell.bashCurrent.fileSystem.metadata(path)) ?? nil != nil
        case "-f":
            let m = try? await Shell.bashCurrent.fileSystem.metadata(path)
            return m?.kind == .file
        case "-d":
            let m = try? await Shell.bashCurrent.fileSystem.metadata(path)
            return m?.kind == .directory
        case "-s":
            let m = try? await Shell.bashCurrent.fileSystem.metadata(path)
            return (m?.size ?? 0) > 0
        case "-r", "-w", "-x":
            // No permission model; report true iff the path exists.
            // RealFileSystem could be enhanced later via `access(2)`.
            let m = try? await Shell.bashCurrent.fileSystem.metadata(path)
            return m != nil
        case "-L", "-h":
            // We don't expose a separate symlink-stat from the FS yet;
            // metadata follows links. Conservatively report false.
            return false
        case "-z":
            return arg.isEmpty
        case "-n":
            return !arg.isEmpty
        case "-t":
            // `[ -t N ]` — is fd N attached to a terminal? Looks up
            // the shell's per-fd `stdinIsTTY` / `stdoutIsTTY` /
            // `stderrIsTTY` flags. Embedders set these; pipelines
            // flip them off for piped stages. Unknown fd → false,
            // matching bash on a sandboxed file descriptor.
            switch arg {
            case "0": return Shell.bashCurrent.stdinIsTTY
            case "1": return Shell.bashCurrent.stdoutIsTTY
            case "2": return Shell.bashCurrent.stderrIsTTY
            default:  return false
            }
        case "-b", "-c", "-p", "-S", "-g", "-u", "-k":
            // Block/char/pipe/socket/setgid/setuid/sticky — not
            // modelled; report false rather than fail.
            return false
        default:
            throw TestError(message: "unknown unary operator: `\(op)'")
        }
    }

    // MARK: Binary evaluation

    private func evalBinary(lhs: String, op: String, rhs: String) async throws -> Bool
    {
        switch op {
        // String
        case "=", "==": return lhs == rhs
        case "!=":      return lhs != rhs
        case "<":       return lhs < rhs
        case ">":       return lhs > rhs

        // Integer
        case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
            guard let l = Int64(lhs.trimmingCharacters(in: .whitespaces)),
                  let r = Int64(rhs.trimmingCharacters(in: .whitespaces))
            else {
                throw TestError(message:
                    "integer expression expected: `\(lhs)' \(op) `\(rhs)'")
            }
            switch op {
            case "-eq": return l == r
            case "-ne": return l != r
            case "-lt": return l < r
            case "-le": return l <= r
            case "-gt": return l > r
            case "-ge": return l >= r
            default: return false
            }

        // File mtime / identity comparison.
        case "-nt", "-ot", "-ef":
            let lp = Shell.bashCurrent.resolvePath(lhs)
            let rp = Shell.bashCurrent.resolvePath(rhs)
            let lm = try? await Shell.bashCurrent.fileSystem.metadata(lp)
            let rm = try? await Shell.bashCurrent.fileSystem.metadata(rp)
            switch op {
            case "-nt":
                // True if `lhs` exists and either rhs is missing or
                // lhs is newer.
                guard let l = lm else { return false }
                guard let r = rm else { return true }
                return l.modifiedAt > r.modifiedAt
            case "-ot":
                guard let r = rm else { return false }
                guard let l = lm else { return true }
                return l.modifiedAt < r.modifiedAt
            case "-ef":
                // Same file: compare canonicalised paths. Without
                // device/inode info this is the closest we can get.
                let lc = try? await Shell.bashCurrent.fileSystem.canonicalize(
                    lp, allowMissing: false)
                let rc = try? await Shell.bashCurrent.fileSystem.canonicalize(
                    rp, allowMissing: false)
                return lc != nil && lc == rc
            default: return false
            }

        default:
            throw TestError(message: "unknown binary operator: `\(op)'")
        }
    }
}

// MARK: Array safe indexing

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
