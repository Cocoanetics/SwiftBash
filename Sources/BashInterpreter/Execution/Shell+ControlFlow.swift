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
        guard let body = firstNonReserved(in: parts, startingAt: doIndex + 1)
        else {
            throw BashInterpreterError.unimplemented("for: missing body")
        }

        loopDepth += 1
        defer { loopDepth -= 1 }

        // `for VAR; do … done` (no `in` clause) iterates over the
        // shell's positional parameters — `$1, $2, …`.
        if !hasIn {
            return try await runForBody(varName: varName,
                                        values: positionalParameters,
                                        body: body)
        }

        // The `in WORDS` clause is subject to the full word-expansion
        // pipeline (including `"$@"` boundary merge and IFS splitting),
        // so `for x in "$@"`, `for x in $VAR`, and `for x in $(seq 3)`
        // all iterate the right number of times.
        var allValues: [String] = []
        for item in items {
            allValues.append(contentsOf: try await expandToArgs(word: item))
        }
        return try await runForBody(varName: varName,
                                    values: allValues,
                                    body: body)
    }

    /// Run a `for` loop body once per pre-resolved value (already-
    /// expanded strings, no further word splitting). Used by the
    /// `for VAR; do … done` (positional) form.
    private func runForBody(varName: String,
                            values: [String],
                            body: Node) async throws -> ExitStatus
    {
        var last = ExitStatus.success
        loop: for value in values {
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
        return last
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

    /// Execute `{ … ; }` or `( … )`. Brace groups share the parent
    /// shell — they're just sequencing. Subshells (`(...)`) run in
    /// an isolated copy so environment mutations and `cd` calls stay
    /// local, matching bash. We detect subshells by the leading `(`
    /// reservedWord that the parser inserts.
    func executeGroup(list: [Node]) async throws -> ExitStatus {
        if isSubshellGroup(list) {
            return try await executeSubshellGroup(list: list)
        }
        var last = ExitStatus.success
        for node in list {
            if case .reservedWord = node.kind { continue }
            last = try await execute(node)
            lastExitStatus = last
        }
        return last
    }

    /// Run `( … )` in a sub-`Shell` with a copied environment, so
    /// assignments, `cd`, `unset`, and `export` inside don't leak out.
    /// stdout/stderr/stdin/commands/fileSystem are inherited, so
    /// output, redirection, and command lookup work normally.
    private func executeSubshellGroup(list: [Node]) async throws -> ExitStatus {
        let sub = makeSubshell()
        sub.stdin = stdin
        sub.currentSource = currentSource
        sub.lastExitStatus = lastExitStatus

        var last = ExitStatus.success
        for node in list {
            if case .reservedWord = node.kind { continue }
            last = try await sub.execute(node)
            sub.lastExitStatus = last
        }
        // The exit status — but NOT the env mutations — propagates back.
        lastExitStatus = last
        return last
    }

    private func isSubshellGroup(_ list: [Node]) -> Bool {
        guard let first = list.first,
              case .reservedWord(let w) = first.kind
        else { return false }
        return w == "("
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
