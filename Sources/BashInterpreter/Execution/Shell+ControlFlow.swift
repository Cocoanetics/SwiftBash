import Foundation
import BashSyntax

extension Shell {

    // MARK: if

    /// `if cond; then … [elif cond; then …]* [else …]? fi`
    ///
    /// Parts layout (per ``Parser``):
    /// `[ "if", cond, "then", body, ("elif", cond, "then", body)*, ("else", body)?, "fi" ]`
    ///
    /// The exit status of the selected branch's body is returned. If no
    /// branch runs, the exit status is `.success` (matching bash).
    func executeIf(parts: [Node]) async throws -> ExitStatus {
        var i = 0
        while i < parts.count {
            guard case .reservedWord(let word) = parts[i].kind else {
                i += 1; continue
            }
            switch word {
            case "if", "elif":
                // We expect: reserved, cond, "then", body.
                guard i + 3 < parts.count else { return .success }
                let cond = parts[i + 1]
                let body = parts[i + 3]
                let condStatus = try await execute(cond)
                lastExitStatus = condStatus
                if condStatus.isSuccess {
                    let result = try await execute(body)
                    lastExitStatus = result
                    return result
                }
                i += 4 // skip past "then <body>"

            case "else":
                guard i + 1 < parts.count else { return .success }
                let result = try await execute(parts[i + 1])
                lastExitStatus = result
                return result

            case "fi":
                return .success

            default:
                i += 1
            }
        }
        return .success
    }

    // MARK: while / until

    /// `while cond; do body; done` or `until cond; do body; done`.
    /// - Parameter invert: When `true`, the loop runs *until* `cond` succeeds
    ///   (i.e., continues while it fails). Used for `until`.
    func executeWhileLike(parts: [Node], invert: Bool) async throws -> ExitStatus {
        // Expected: [ kw, cond, "do", body, "done" ]
        // Find cond (first non-reserved after the keyword) and body
        // (first non-reserved after "do") so we're tolerant of trailing
        // reserved nodes like semicolon operators.
        guard let cond = firstNonReserved(in: parts, startingAt: 1),
              let doIndex = indexOfReserved("do", in: parts),
              let body = firstNonReserved(in: parts, startingAt: doIndex + 1)
        else {
            throw BashInterpreterError.unimplemented("malformed while/until")
        }

        loopDepth += 1
        defer { loopDepth -= 1 }

        var last = ExitStatus.success
        var iterations = 0
        let maxIterations = 1_000_000 // guard against runaway loops
        loop: while true {
            let condStatus = try await execute(cond)
            let keepGoing = invert ? !condStatus.isSuccess : condStatus.isSuccess
            if !keepGoing { break }
            do {
                last = try await execute(body)
                lastExitStatus = last
            } catch var signal as LoopControlSignal {
                signal.remainingLevels -= 1
                if signal.remainingLevels > 0 { throw signal }
                switch signal.kind {
                case .breakLoop:    break loop
                case .continueLoop: continue loop
                }
            }
            iterations += 1
            if iterations > maxIterations {
                throw BashInterpreterError.io(
                    "loop exceeded \(maxIterations) iterations; aborting")
            }
        }
        return last
    }

    // MARK: for

    /// `for VAR in WORDS; do BODY; done`.
    ///
    /// Parts layout (per ``Parser``):
    /// `[ "for", varWord, "in", word*, (";")?, "do", body, "done" ]`
    ///
    /// The `in` clause is required in this skeleton; implicit iteration
    /// over positional parameters (`for x; do …`) throws `unimplemented`.
    func executeFor(parts: [Node]) async throws -> ExitStatus {
        guard parts.count >= 2,
              case .word(let varName, _) = parts[1].kind
        else {
            throw BashInterpreterError.unimplemented("malformed for")
        }

        // Find "in" (optional) and "do" (required).
        var hasIn = false
        var items: [Node] = []
        var doIndex = -1
        var i = 2
        while i < parts.count {
            if case .reservedWord(let w) = parts[i].kind {
                if w == "in" {
                    hasIn = true
                    i += 1
                    while i < parts.count {
                        if case .reservedWord = parts[i].kind { break }
                        items.append(parts[i])
                        i += 1
                    }
                    continue
                }
                if w == "do" { doIndex = i; break }
            }
            i += 1
        }

        guard doIndex >= 0 else {
            throw BashInterpreterError.unimplemented("for: missing 'do'")
        }
        if !hasIn {
            throw BashInterpreterError.unimplemented(
                "for VAR; do … done (positional parameters not supported)")
        }
        guard let body = firstNonReserved(in: parts, startingAt: doIndex + 1)
        else {
            throw BashInterpreterError.unimplemented("for: missing body")
        }

        loopDepth += 1
        defer { loopDepth -= 1 }

        var last = ExitStatus.success
        loop: for item in items {
            // `for x in $(seq 3)` must iterate three times — i.e., the
            // expansion of a substitution in the `in` clause is
            // word-split. Literal words pass through unchanged.
            let expanded = try await expand(word: item)
            let values = splitForLoopWord(expanded, originalWord: item)
            for value in values {
                environment[varName] = value
                do {
                    last = try await execute(body)
                    lastExitStatus = last
                } catch var signal as LoopControlSignal {
                    signal.remainingLevels -= 1
                    if signal.remainingLevels > 0 { throw signal }
                    switch signal.kind {
                    case .breakLoop:    break loop
                    case .continueLoop: continue loop
                    }
                }
            }
        }
        return last
    }

    /// Approximate bash word splitting for the `for … in …` position.
    /// Only words that contained a substitution are split — literal
    /// words pass through unchanged. Splits on whitespace runs
    /// (space, tab, newline), matching the default `IFS`.
    private func splitForLoopWord(_ expanded: String,
                                  originalWord: Node) -> [String] {
        let hasSubstitution: Bool
        switch originalWord.kind {
        case .word(_, let parts), .assignment(_, let parts):
            hasSubstitution = parts.contains { part in
                switch part.kind {
                case .parameter, .commandSubstitution,
                     .arithmeticSubstitution, .tilde:
                    return true
                default:
                    return false
                }
            }
        default:
            hasSubstitution = false
        }
        if !hasSubstitution { return [expanded] }
        return expanded
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    // MARK: case

    /// `case WORD in PAT) body ;; … esac`.
    ///
    /// Parts layout (per ``Parser``):
    /// `[ "case", subjectWord, "in", armCompound, (";;" | ";&" | ";;&"), … , "esac" ]`
    ///
    /// Each arm is a `.compound` whose list contains:
    ///   `[("(")?, pattern, ")", body?]`
    ///
    /// Arm terminators control fall-through:
    /// - `;;`  → stop after running the body (default, and the vast majority).
    /// - `;&`  → fall through to the *next* arm's body unconditionally.
    /// - `;;&` → continue testing subsequent patterns.
    func executeCase(parts: [Node]) async throws -> ExitStatus {
        // Expected: [ "case", <subject>, "in", arm, term, arm, term, …, "esac" ]
        guard parts.count >= 4 else { return .success }
        let subjectValue = try await expand(word: parts[1])

        // Collect (arm, terminator) pairs.
        var arms: [(Node, String)] = []
        var i = 3
        while i < parts.count {
            let arm = parts[i]
            if case .reservedWord(let w) = arm.kind, w == "esac" { break }
            var term = ";;"
            if i + 1 < parts.count,
               case .reservedWord(let t) = parts[i + 1].kind,
               t == ";;" || t == ";&" || t == ";;&"
            {
                term = t
                i += 2
            } else {
                i += 1
            }
            arms.append((arm, term))
        }

        var last = ExitStatus.success
        var forceFallThrough = false
        for (arm, term) in arms {
            guard case .compound(let armParts, _) = arm.kind else { continue }

            let matched: Bool
            if forceFallThrough {
                matched = true
            } else {
                matched = try await armMatches(subjectValue, armParts: armParts)
            }
            if !matched { continue }

            // Execute the body if present (anything that isn't a
            // reservedWord or the pattern itself).
            for node in armParts {
                switch node.kind {
                case .reservedWord, .pattern: continue
                default:
                    last = try await execute(node)
                    lastExitStatus = last
                }
            }

            switch term {
            case ";;":  return last
            case ";&":
                // Run the next arm's body unconditionally.
                forceFallThrough = true
            case ";;&":
                // Continue testing subsequent patterns.
                forceFallThrough = false
            default:
                return last
            }
        }
        return last
    }

    /// Evaluates whether any of an arm's patterns match `subject`.
    private func armMatches(_ subject: String, armParts: [Node]) async throws -> Bool {
        for node in armParts {
            guard case .pattern(let patterns) = node.kind else { continue }
            for sub in patterns {
                if case .reservedWord = sub.kind { continue }
                let expanded = try await expand(word: sub)
                if GlobMatcher.match(pattern: expanded, string: subject) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Group / subshell

    /// Execute `{ … ; }` or `( … )` — run each non-reservedWord child in
    /// order. Subshells don't get env isolation in this skeleton (no
    /// subprocess model yet); callers should be aware mutations leak out.
    func executeGroup(list: [Node]) async throws -> ExitStatus {
        var last = ExitStatus.success
        for node in list {
            if case .reservedWord = node.kind { continue }
            last = try await execute(node)
            lastExitStatus = last
        }
        return last
    }

    /// Emit a bash-style warning when `break` / `continue` fires outside
    /// any enclosing loop.
    func warnStrayLoopControl(_ signal: LoopControlSignal) {
        let name = signal.kind == .breakLoop ? "break" : "continue"
        stderr("bash: \(name): only meaningful in a `for', `while', "
             + "or `until' loop\n")
    }

    // MARK: helpers

    private func firstNonReserved(in nodes: [Node], startingAt start: Int) -> Node? {
        var i = start
        while i < nodes.count {
            if case .reservedWord = nodes[i].kind {
                i += 1; continue
            }
            return nodes[i]
        }
        return nil
    }

    private func indexOfReserved(_ word: String, in nodes: [Node]) -> Int? {
        for (i, n) in nodes.enumerated() {
            if case .reservedWord(let w) = n.kind, w == word { return i }
        }
        return nil
    }
}
