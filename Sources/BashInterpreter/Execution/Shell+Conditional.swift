import Foundation
import BashSyntax

extension Shell {

    /// Evaluate a `[[ EXPR ]]` conditional. Returns `.success` (exit 0)
    /// if the expression is true, `.failure` (exit 1) if false. Bash
    /// rules that distinguish `[[ ]]` from plain `test` / `[ ]`:
    ///
    /// - **No word splitting** on substitution results — even if `IFS`
    ///   or the value contains whitespace, each operand is *one* token.
    /// - `==` and `!=` use **glob-style pattern matching** when the
    ///   right-hand side is unquoted; quoted RHS forces literal compare.
    /// - `=~` is **regex match**: `[[ "$x" =~ ^[0-9]+$ ]]`.
    /// - `<` and `>` are **string comparison**, not redirection.
    /// - `&&` and `||` are **logical operators** with normal
    ///   short-circuit evaluation, not list separators.
    func executeConditional(parts: [Node]) async throws -> ExitStatus {
        // Drop separator markers the parser inserts for newlines/`;`
        // inside `[[ … ]]`. Bash treats those as whitespace.
        let cleaned = parts.filter { node in
            if case .operator(let op) = node.kind, op == ";" {
                return false
            }
            return true
        }
        var ev = ConditionalEvaluator(parts: cleaned)
        let value = try await ev.parseOr(shell: self)
        if !ev.isAtEnd {
            throw BashInterpreterError.parameter(
                "[[: unexpected token at position \(ev.position)")
        }
        return value ? .success : .failure
    }
}

// MARK: Recursive-descent evaluator

/// Mirrors the test expression grammar, but with `&&` / `||` instead
/// of `-a` / `-o` and with operands kept as ``Node``s so we can
/// distinguish quoted vs. unquoted right-hand sides for pattern
/// matching.
private struct ConditionalEvaluator {
    let parts: [Node]
    var pos = 0

    init(parts: [Node]) { self.parts = parts }

    var isAtEnd: Bool { pos >= parts.count }
    var position: Int { pos }

    private func peek() -> Node? {
        pos < parts.count ? parts[pos] : nil
    }
    private mutating func advance() -> Node? {
        guard pos < parts.count else { return nil }
        let n = parts[pos]
        pos += 1
        return n
    }

    private func operatorAt(_ offset: Int) -> String? {
        let i = pos + offset
        guard i < parts.count else { return nil }
        if case .operator(let op) = parts[i].kind { return op }
        return nil
    }

    private func reservedAt(_ offset: Int) -> String? {
        let i = pos + offset
        guard i < parts.count else { return nil }
        if case .reservedWord(let w) = parts[i].kind { return w }
        return nil
    }

    private func wordValueAt(_ offset: Int) -> String? {
        let i = pos + offset
        guard i < parts.count else { return nil }
        if case .word(let w, _) = parts[i].kind { return w }
        return nil
    }

    // MARK: Grammar

    mutating func parseOr(shell: Shell, skip: Bool = false) async throws -> Bool {
        var left = try await parseAnd(shell: shell, skip: skip)
        while operatorAt(0) == "||" {
            _ = advance()
            // Short-circuit: when the left side is already true, the
            // right side is parsed (to consume tokens) but not
            // evaluated for side-effects.
            let right = try await parseAnd(shell: shell, skip: skip || left)
            left = left || right
        }
        return left
    }

    private mutating func parseAnd(shell: Shell, skip: Bool)
        async throws -> Bool
    {
        var left = try await parseNot(shell: shell, skip: skip)
        while operatorAt(0) == "&&" {
            _ = advance()
            let right = try await parseNot(shell: shell, skip: skip || !left)
            left = left && right
        }
        return left
    }

    private mutating func parseNot(shell: Shell, skip: Bool)
        async throws -> Bool
    {
        if isBang(parts[safe: pos]) {
            _ = advance()
            return !(try await parseNot(shell: shell, skip: skip))
        }
        return try await parsePrimary(shell: shell, skip: skip)
    }

    /// `!` arrives either as `.reservedWord("!")` (when the parser
    /// happened to fire its bang-keyword rule) or as a plain
    /// `.word("!")`. Accept either form.
    private func isBang(_ node: Node?) -> Bool {
        guard let node else { return false }
        if case .reservedWord("!") = node.kind { return true }
        if case .word("!", _) = node.kind { return true }
        return false
    }

    private mutating func parsePrimary(shell: Shell, skip: Bool)
        async throws -> Bool
    {
        if reservedAt(0) == "(" {
            _ = advance()
            let inner = try await parseOr(shell: shell, skip: skip)
            guard reservedAt(0) == ")" else {
                throw BashInterpreterError.parameter(
                    "[[: expected `)' to close `('")
            }
            _ = advance()
            return inner
        }

        if pos + 2 < parts.count, isBinaryOpNode(parts[pos + 1]) {
            let lhsNode = parts[pos]
            let opNode = parts[pos + 1]
            let rhsNode = parts[pos + 2]
            pos += 3
            if skip { return false }
            return try await evalBinary(
                lhs: lhsNode, op: opNode, rhs: rhsNode, shell: shell)
        }
        if pos + 2 < parts.count,
           let opStr = operatorAtIndex(pos + 1),
           opStr == "<" || opStr == ">"
        {
            let lhs = parts[pos]
            let rhs = parts[pos + 2]
            pos += 3
            if skip { return false }
            let l = try await shell.expand(word: lhs)
            let r = try await shell.expand(word: rhs)
            return opStr == "<" ? (l < r) : (l > r)
        }

        if pos + 1 < parts.count,
           let opStr = wordValueAt(0),
           Self.unaryOps.contains(opStr)
        {
            _ = advance()
            let argNode = advance()!
            if skip { return false }
            return try await evalUnary(op: opStr, arg: argNode, shell: shell)
        }

        guard let node = advance() else {
            throw BashInterpreterError.parameter(
                "[[: empty expression")
        }
        if skip { return false }
        let value = try await shell.expand(word: node)
        return !value.isEmpty
    }

    private func operatorAtIndex(_ i: Int) -> String? {
        guard i < parts.count else { return nil }
        if case .operator(let op) = parts[i].kind { return op }
        return nil
    }

    private func isBinaryOpNode(_ node: Node) -> Bool {
        if case .word(let w, _) = node.kind, Self.binaryOps.contains(w) {
            return true
        }
        return false
    }

    // MARK: Operator tables

    private static let unaryOps: Set<String> = [
        "-e", "-f", "-d", "-s", "-r", "-w", "-x",
        "-L", "-h", "-z", "-n", "-b", "-c", "-p", "-S", "-t", "-g", "-u", "-k"
    ]

    /// Binary operators that arrive as word tokens.
    private static let binaryOps: Set<String> = [
        "=", "==", "!=", "=~",
        "-eq", "-ne", "-lt", "-le", "-gt", "-ge",
        "-nt", "-ot", "-ef"
    ]

    // MARK: Operator dispatch

    private func evalUnary(op: String, arg: Node,
                           shell: Shell) async throws -> Bool
    {
        let value = try await shell.expand(word: arg)
        switch op {
        case "-z": return value.isEmpty
        case "-n": return !value.isEmpty
        case "-e", "-f", "-d", "-s", "-r", "-w", "-x":
            let path = shell.resolvePath(value)
            let m = try? await shell.fileSystem.metadata(path)
            switch op {
            case "-e": return m != nil
            case "-f": return m?.kind == .file
            case "-d": return m?.kind == .directory
            case "-s": return (m?.size ?? 0) > 0
            case "-r", "-w", "-x": return m != nil
            default: return false
            }
        case "-L", "-h",
             "-b", "-c", "-p", "-S", "-t", "-g", "-u", "-k":
            return false
        default:
            throw BashInterpreterError.parameter(
                "[[: unknown unary operator: `\(op)'")
        }
    }

    private func evalBinary(lhs: Node, op: Node, rhs: Node,
                            shell: Shell) async throws -> Bool
    {
        guard case .word(let opStr, _) = op.kind else {
            throw BashInterpreterError.parameter("[[: bad binary operator")
        }
        let lValue = try await shell.expand(word: lhs)

        switch opStr {
        case "=", "==":
            // Quoted RHS → literal compare. Unquoted → glob match.
            if rhsIsLiteral(rhs, shell: shell) {
                let rValue = try await shell.expand(word: rhs)
                return lValue == rValue
            } else {
                let rValue = try await shell.expand(word: rhs)
                return GlobMatcher.match(pattern: rValue, string: lValue)
            }
        case "!=":
            if rhsIsLiteral(rhs, shell: shell) {
                let rValue = try await shell.expand(word: rhs)
                return lValue != rValue
            } else {
                let rValue = try await shell.expand(word: rhs)
                return !GlobMatcher.match(pattern: rValue, string: lValue)
            }
        case "=~":
            // Regex match. Always literal comparison — regex syntax
            // doesn't go through glob.
            let rValue = try await shell.expand(word: rhs)
            do {
                let regex = try NSRegularExpression(pattern: rValue)
                let range = NSRange(lValue.startIndex..., in: lValue)
                return regex.firstMatch(in: lValue, range: range) != nil
            } catch {
                throw BashInterpreterError.parameter(
                    "[[: invalid regex `\(rValue)': \(error.localizedDescription)")
            }
        case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
            let rValue = try await shell.expand(word: rhs)
            guard let l = Int64(lValue.trimmingCharacters(in: .whitespaces)),
                  let r = Int64(rValue.trimmingCharacters(in: .whitespaces))
            else {
                throw BashInterpreterError.parameter(
                    "[[: integer expected: `\(lValue)' \(opStr) `\(rValue)'")
            }
            switch opStr {
            case "-eq": return l == r
            case "-ne": return l != r
            case "-lt": return l < r
            case "-le": return l <= r
            case "-gt": return l > r
            case "-ge": return l >= r
            default: return false
            }
        case "-nt", "-ot", "-ef":
            let rValue = try await shell.expand(word: rhs)
            let lp = shell.resolvePath(lValue)
            let rp = shell.resolvePath(rValue)
            let lm = try? await shell.fileSystem.metadata(lp)
            let rm = try? await shell.fileSystem.metadata(rp)
            switch opStr {
            case "-nt":
                guard let l = lm else { return false }
                guard let r = rm else { return true }
                return l.modifiedAt > r.modifiedAt
            case "-ot":
                guard let r = rm else { return false }
                guard let l = lm else { return true }
                return l.modifiedAt < r.modifiedAt
            case "-ef":
                let lc = try? await shell.fileSystem.canonicalize(
                    lp, allowMissing: false)
                let rc = try? await shell.fileSystem.canonicalize(
                    rp, allowMissing: false)
                return lc != nil && lc == rc
            default: return false
            }
        default:
            throw BashInterpreterError.parameter(
                "[[: unknown binary operator: `\(opStr)'")
        }
    }

    /// Whether the RHS word's *source* contained any quote or
    /// backslash. `[[ $x == "*.txt" ]]` does literal compare;
    /// `[[ $x == *.txt ]]` does glob match. The parser strips quote
    /// characters from a word's value but keeps them in the original
    /// source range, so we inspect that.
    private func rhsIsLiteral(_ node: Node, shell: Shell) -> Bool {
        let chars = Array(shell.currentSource)
        let lo = max(0, node.range.lowerBound)
        let hi = min(chars.count, node.range.upperBound)
        for i in lo..<hi {
            let c = chars[i]
            if c == "'" || c == "\"" || c == "\\" { return true }
        }
        return false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
