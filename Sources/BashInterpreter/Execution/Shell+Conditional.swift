// swiftlint:disable file_length
// Conditional `[[ ]]` evaluator — splitting the grammar walker and
// operator dispatcher would scatter their shared state.
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
            if case .operator(let opText) = node.kind, opText == ";" {
                return false
            }
            return true
        }
        var evaluator = ConditionalEvaluator(parts: cleaned)
        let value = try await evaluator.parseOr()
        if !evaluator.isAtEnd {
            throw BashInterpreterError.parameter(
                "[[: unexpected token at position \(evaluator.position)")
        }
        return value ? .success : .failure
    }
}

// MARK: Recursive-descent evaluator

// Mirrors the test expression grammar, but with `&&` / `||` instead
// of `-a` / `-o` and with operands kept as ``Node``s so we can
// distinguish quoted vs. unquoted right-hand sides for pattern matching.
// swiftlint:disable:next type_body_length
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
        let node = parts[pos]
        pos += 1
        return node
    }

    private func operatorAt(_ offset: Int) -> String? {
        let idx = pos + offset
        guard idx < parts.count else { return nil }
        if case .operator(let opText) = parts[idx].kind { return opText }
        return nil
    }

    private func reservedAt(_ offset: Int) -> String? {
        let idx = pos + offset
        guard idx < parts.count else { return nil }
        if case .reservedWord(let word) = parts[idx].kind { return word }
        return nil
    }

    private func wordValueAt(_ offset: Int) -> String? {
        let idx = pos + offset
        guard idx < parts.count else { return nil }
        if case .word(let word, _) = parts[idx].kind { return word }
        return nil
    }

    // MARK: Grammar

    mutating func parseOr(skip: Bool = false) async throws -> Bool {
        var left = try await parseAnd(skip: skip)
        while operatorAt(0) == "||" {
            _ = advance()
            // Short-circuit: when the left side is already true, the
            // right side is parsed (to consume tokens) but not
            // evaluated for side-effects.
            let right = try await parseAnd(skip: skip || left)
            left = left || right
        }
        return left
    }

    private mutating func parseAnd(skip: Bool)
        async throws -> Bool {
        var left = try await parseNot(skip: skip)
        while operatorAt(0) == "&&" {
            _ = advance()
            let right = try await parseNot(skip: skip || !left)
            left = left && right
        }
        return left
    }

    private mutating func parseNot(skip: Bool)
        async throws -> Bool {
        if isBang(parts[safe: pos]) {
            _ = advance()
            return !(try await parseNot(skip: skip))
        }
        return try await parsePrimary(skip: skip)
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

    private mutating func parsePrimary(skip: Bool)
        async throws -> Bool {
        if reservedAt(0) == "(" {
            _ = advance()
            let inner = try await parseOr(skip: skip)
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
                lhs: lhsNode, op: opNode, rhs: rhsNode)
        }
        if pos + 2 < parts.count,
           let opStr = operatorAtIndex(pos + 1),
           opStr == "<" || opStr == ">" {
            let lhs = parts[pos]
            let rhs = parts[pos + 2]
            pos += 3
            if skip { return false }
            let lhsValue = try await Shell.bashCurrent.expand(word: lhs)
            let rhsValue = try await Shell.bashCurrent.expand(word: rhs)
            return opStr == "<" ? (lhsValue < rhsValue) : (lhsValue > rhsValue)
        }

        if pos + 1 < parts.count,
           let opStr = wordValueAt(0),
           Self.unaryOps.contains(opStr) {
            _ = advance()
            let argNode = advance()!
            if skip { return false }
            return try await evalUnary(op: opStr, arg: argNode)
        }

        guard let node = advance() else {
            throw BashInterpreterError.parameter(
                "[[: empty expression")
        }
        if skip { return false }
        let value = try await Shell.bashCurrent.expand(word: node)
        return !value.isEmpty
    }

    private func operatorAtIndex(_ idx: Int) -> String? {
        guard idx < parts.count else { return nil }
        if case .operator(let opText) = parts[idx].kind { return opText }
        return nil
    }

    private func isBinaryOpNode(_ node: Node) -> Bool {
        if case .word(let word, _) = node.kind, Self.binaryOps.contains(word) {
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

    // swiftlint:disable:next cyclomatic_complexity
    private func evalUnary(op opText: String, arg: Node) async throws -> Bool {
        let value = try await Shell.bashCurrent.expand(word: arg)
        switch opText {
        case "-z": return value.isEmpty
        case "-n": return !value.isEmpty
        case "-e", "-f", "-d", "-s", "-r", "-w", "-x":
            let path = Shell.bashCurrent.resolvePath(value)
            let meta = try? await Shell.bashCurrent.fileSystem.metadata(path)
            switch opText {
            case "-e": return meta != nil
            case "-f": return meta?.kind == .file
            case "-d": return meta?.kind == .directory
            case "-s": return (meta?.size ?? 0) > 0
            case "-r", "-w", "-x": return meta != nil
            default: return false
            }
        case "-L", "-h",
             "-b", "-c", "-p", "-S", "-t", "-g", "-u", "-k":
            return false
        default:
            throw BashInterpreterError.parameter(
                "[[: unknown unary operator: `\(opText)'")
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func evalBinary(lhs: Node, op opNode: Node, rhs: Node) async throws -> Bool {
        guard case .word(let opStr, _) = opNode.kind else {
            throw BashInterpreterError.parameter("[[: bad binary operator")
        }
        let lValue = try await Shell.bashCurrent.expand(word: lhs)

        switch opStr {
        case "=", "==":
            return try await matchAsGlob(lhs: lValue, rhs: rhs)
        case "!=":
            return try await !matchAsGlob(lhs: lValue, rhs: rhs)
        case "=~":
            // Regex match. Always literal comparison — regex syntax
            // doesn't go through glob.
            let rValue = try await Shell.bashCurrent.expand(word: rhs)
            do {
                let regex = try NSRegularExpression(pattern: rValue)
                let range = NSRange(lValue.startIndex..., in: lValue)
                return regex.firstMatch(in: lValue, range: range) != nil
            } catch {
                throw BashInterpreterError.parameter(
                    "[[: invalid regex `\(rValue)': \(error.localizedDescription)")
            }
        case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
            let rValue = try await Shell.bashCurrent.expand(word: rhs)
            guard let lhsInt = Int64(lValue.trimmingCharacters(in: .whitespaces)),
                  let rhsInt = Int64(rValue.trimmingCharacters(in: .whitespaces))
            else {
                throw BashInterpreterError.parameter(
                    "[[: integer expected: `\(lValue)' \(opStr) `\(rValue)'")
            }
            switch opStr {
            case "-eq": return lhsInt == rhsInt
            case "-ne": return lhsInt != rhsInt
            case "-lt": return lhsInt < rhsInt
            case "-le": return lhsInt <= rhsInt
            case "-gt": return lhsInt > rhsInt
            case "-ge": return lhsInt >= rhsInt
            default: return false
            }
        case "-nt", "-ot", "-ef":
            let rValue = try await Shell.bashCurrent.expand(word: rhs)
            let lhsPath = Shell.bashCurrent.resolvePath(lValue)
            let rhsPath = Shell.bashCurrent.resolvePath(rValue)
            let lhsMeta = try? await Shell.bashCurrent.fileSystem.metadata(lhsPath)
            let rhsMeta = try? await Shell.bashCurrent.fileSystem.metadata(rhsPath)
            switch opStr {
            case "-nt":
                guard let lhsMeta else { return false }
                guard let rhsMeta else { return true }
                return lhsMeta.modifiedAt > rhsMeta.modifiedAt
            case "-ot":
                guard let rhsMeta else { return false }
                guard let lhsMeta else { return true }
                return lhsMeta.modifiedAt < rhsMeta.modifiedAt
            case "-ef":
                let lhsCanonical = try? await Shell.bashCurrent.fileSystem.canonicalize(
                    lhsPath, allowMissing: false)
                let rhsCanonical = try? await Shell.bashCurrent.fileSystem.canonicalize(
                    rhsPath, allowMissing: false)
                return lhsCanonical != nil && lhsCanonical == rhsCanonical
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
    private func rhsIsLiteral(_ node: Node) -> Bool {
        let chars = Array(Shell.bashCurrent.currentSource)
        let low = max(0, node.range.lowerBound)
        let high = min(chars.count, node.range.upperBound)
        for idx in low..<high {
            let char = chars[idx]
            if char == "'" || char == "\"" || char == "\\" { return true }
        }
        return false
    }

    /// `[[ lhs == rhs ]]` — match `lhs` against `rhs` interpreted as a
    /// bash glob, with quoted spans inside `rhs` taken literally and
    /// unquoted spans treated as glob metacharacters. So `"h"*` is the
    /// literal `h` followed by any chars; `'a*b'` is the literal three
    /// characters; an entirely unquoted `*.txt` is a normal glob.
    private func matchAsGlob(lhs: String, rhs: Node) async throws -> Bool {
        let pattern = try await buildGlobPattern(rhs: rhs)
        let opts = GlobOptions(
            extglob: Shell.bashCurrent.shoptOptions["extglob"] == true,
            nocase: Shell.bashCurrent.shoptOptions["nocasematch"] == true)
        return GlobMatcher.match(pattern: pattern, string: lhs, options: opts)
    }

    /// Walk the *source bytes* of `rhs` and build a glob pattern. Chars
    /// that came from inside `'...'` or `"..."` (or were `\\X`-escaped)
    /// are emitted as `\\X` so they match literally; unquoted glob
    /// metacharacters pass through unchanged. Substitutions inside the
    /// rhs are first resolved (parameter / command sub) then their
    /// expanded value is escaped — bash treats substituted text as
    /// literal in `[[ ]]` patterns.
    private func buildGlobPattern(rhs: Node) async throws -> String {
        let chars = Array(Shell.bashCurrent.currentSource)
        let low = max(0, rhs.range.lowerBound)
        let high = min(chars.count, rhs.range.upperBound)
        guard low < high else { return "" }

        // Sort substitution sub-nodes by source position so we can
        // splice them in as we walk.
        let parts: [Node]
        if case .word(_, let inner) = rhs.kind { parts = inner } else { parts = [] }
        var queue = parts.sorted { $0.range.lowerBound < $1.range.lowerBound }

        var out = ""
        var inDouble = false
        var cursor = low
        while cursor < high {
            if let head = queue.first, cursor == head.range.lowerBound {
                let value = try await Shell.bashCurrent.resolve(part: head)
                out.append(escapedForGlob(value))
                cursor = min(high, head.range.upperBound)
                queue.removeFirst()
                continue
            }
            let char = chars[cursor]
            if char == "'", !inDouble {
                cursor += 1
                while cursor < high, chars[cursor] != "'" {
                    out.append(escapedForGlob(String(chars[cursor])))
                    cursor += 1
                }
                if cursor < high { cursor += 1 }
                continue
            }
            if char == "\"" {
                inDouble.toggle()
                cursor += 1
                continue
            }
            if char == "\\", cursor + 1 < high {
                out.append(escapedForGlob(String(chars[cursor + 1])))
                cursor += 2
                continue
            }
            if inDouble {
                out.append(escapedForGlob(String(char)))
            } else {
                out.append(char)
            }
            cursor += 1
        }
        return out
    }

    private func escapedForGlob(_ text: String) -> String {
        var out = ""
        for char in text {
            switch char {
            case "*", "?", "[", "]", "\\", "(", ")", "|":
                out.append("\\")
                out.append(char)
            default:
                out.append(char)
            }
        }
        return out
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
