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
        let token = tokens[pos]
        pos += 1
        return token
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
           Self.binaryOps.contains(mid) {
            let lhs = advance()!
            let operatorToken = advance()!
            let rhs = advance()!
            return try await evalBinary(
                lhs: lhs, op: operatorToken, rhs: rhs)
        }
        if remaining >= 2,
           let first = peek(),
           Self.unaryOps.contains(first) {
            let operatorToken = advance()!
            let arg = advance()!
            return try await evalUnary(op: operatorToken, arg: arg)
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

    // Flat dispatch over the `test` unary operator table (`-e`, `-f`,
    // `-d`, etc.); one case per operator.
    // swiftlint:disable:next cyclomatic_complexity
    private func evalUnary(op operatorToken: String, arg: String) async throws -> Bool {
        let path = Shell.bashCurrent.resolvePath(arg)
        switch operatorToken {
        case "-e":
            return (try? await Shell.bashCurrent.fileSystem.metadata(path)) ?? nil != nil
        case "-f":
            let meta = try? await Shell.bashCurrent.fileSystem.metadata(path)
            return meta?.kind == .file
        case "-d":
            let meta = try? await Shell.bashCurrent.fileSystem.metadata(path)
            return meta?.kind == .directory
        case "-s":
            let meta = try? await Shell.bashCurrent.fileSystem.metadata(path)
            return (meta?.size ?? 0) > 0
        case "-r", "-w", "-x":
            // No permission model; report true iff the path exists.
            // RealFileSystem could be enhanced later via `access(2)`.
            let meta = try? await Shell.bashCurrent.fileSystem.metadata(path)
            return meta != nil
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
            throw TestError(message: "unknown unary operator: `\(operatorToken)'")
        }
    }

    // MARK: Binary evaluation

    // Flat dispatch over `test`'s binary operator table (string `=` /
    // `<` / `>`, integer `-eq` / `-lt` / etc., file `-nt` / `-ot` /
    // `-ef`); per-group helpers would lose the shared dispatch site.
    // swiftlint:disable:next cyclomatic_complexity
    private func evalBinary(lhs: String,
                            op operatorToken: String,
                            rhs: String) async throws -> Bool {
        switch operatorToken {
        // String
        case "=", "==": return lhs == rhs
        case "!=":      return lhs != rhs
        case "<":       return lhs < rhs
        case ">":       return lhs > rhs

        // Integer
        case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
            guard let lhsNum = Int64(lhs.trimmingCharacters(in: .whitespaces)),
                  let rhsNum = Int64(rhs.trimmingCharacters(in: .whitespaces))
            else {
                throw TestError(message:
                    "integer expression expected: `\(lhs)' \(operatorToken) `\(rhs)'")
            }
            switch operatorToken {
            case "-eq": return lhsNum == rhsNum
            case "-ne": return lhsNum != rhsNum
            case "-lt": return lhsNum < rhsNum
            case "-le": return lhsNum <= rhsNum
            case "-gt": return lhsNum > rhsNum
            case "-ge": return lhsNum >= rhsNum
            default: return false
            }

        // File mtime / identity comparison.
        case "-nt", "-ot", "-ef":
            let lhsPath = Shell.bashCurrent.resolvePath(lhs)
            let rhsPath = Shell.bashCurrent.resolvePath(rhs)
            let lhsMeta = try? await Shell.bashCurrent.fileSystem.metadata(lhsPath)
            let rhsMeta = try? await Shell.bashCurrent.fileSystem.metadata(rhsPath)
            switch operatorToken {
            case "-nt":
                // True if `lhs` exists and either rhs is missing or
                // lhs is newer.
                guard let lhsM = lhsMeta else { return false }
                guard let rhsM = rhsMeta else { return true }
                return lhsM.modifiedAt > rhsM.modifiedAt
            case "-ot":
                guard let rhsM = rhsMeta else { return false }
                guard let lhsM = lhsMeta else { return true }
                return lhsM.modifiedAt < rhsM.modifiedAt
            case "-ef":
                // Same file: compare canonicalised paths. Without
                // device/inode info this is the closest we can get.
                let lhsCanon = try? await Shell.bashCurrent.fileSystem.canonicalize(
                    lhsPath, allowMissing: false)
                let rhsCanon = try? await Shell.bashCurrent.fileSystem.canonicalize(
                    rhsPath, allowMissing: false)
                return lhsCanon != nil && lhsCanon == rhsCanon
            default: return false
            }

        default:
            throw TestError(message: "unknown binary operator: `\(operatorToken)'")
        }
    }
}

// MARK: Array safe indexing

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
