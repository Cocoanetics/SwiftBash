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
                errexitGuard += 1
                let condStatus: ExitStatus
                do { condStatus = try await execute(cond) }
                catch { errexitGuard -= 1; throw error }
                errexitGuard -= 1
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
            // Cooperative cancel point — lets `kill PID` against this
            // backgrounded loop actually stop. CancellationError unwinds
            // up to the spawning Task, which records the entry as
            // `.cancelled`.
            try Task.checkCancellation()
            errexitGuard += 1
            let condStatus: ExitStatus
            do { condStatus = try await execute(cond) }
            catch { errexitGuard -= 1; throw error }
            errexitGuard -= 1
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
            // Periodic cooperative yield. Without it, a tight body
            // (e.g. `i=$((i+1))` with no awaits) keeps the executor
            // pinned and other tasks — including the one that issued
            // `kill PID` — never get a chance to run on a single-CPU
            // host like the Android emulator. Yielding every ~1k
            // iterations is cheap (one context switch) and ensures
            // cancellation actually lands.
            if iterations.isMultiple(of: 1024) {
                await Task.yield()
            }
            if iterations > maxIterations {
                // Runaway-loop guard. If the task is *also* cancelled,
                // surface that as cancellation (143) rather than as a
                // generic interpreter error (1).
                if Task.isCancelled {
                    throw CancellationError()
                }
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

    /// Run a C-style `for ((init; cond; update)); do … done`. Empty
    /// `cond` is "always true" — `for ((;;))` loops forever (subject
    /// to `break`). Exit status is the body's last status, or
    /// `.success` if the loop never runs.
    func executeCStyleFor(initExpr: String, condExpr: String,
                          updateExpr: String, body: Node) async throws -> ExitStatus
    {
        loopDepth += 1
        defer { loopDepth -= 1 }

        if !initExpr.isEmpty {
            _ = try await evaluateArithmetic(initExpr)
        }

        var last = ExitStatus.success
        var iterations = 0
        loop: while true {
            try Task.checkCancellation()
            // Periodic cooperative yield (see runForBody / executeWhile).
            if iterations.isMultiple(of: 1024) {
                await Task.yield()
            }
            iterations += 1
            if !condExpr.isEmpty {
                errexitGuard += 1
                let v: Int64
                do { v = try await evaluateArithmetic(condExpr) }
                catch { errexitGuard -= 1; throw error }
                errexitGuard -= 1
                if v == 0 { break }
            }
            do {
                last = try await execute(body)
                lastExitStatus = last
            } catch var signal as LoopControlSignal {
                signal.remainingLevels -= 1
                if signal.remainingLevels > 0 { throw signal }
                switch signal.kind {
                case .breakLoop:    break loop
                case .continueLoop: break // fall through to update
                }
            }
            if !updateExpr.isEmpty {
                _ = try await evaluateArithmetic(updateExpr)
            }
        }
        return last
    }

    /// Run a `for` loop body once per pre-resolved value (already-
    /// expanded strings, no further word splitting). Used by the
    /// `for VAR; do … done` (positional) form.
    private func runForBody(varName: String,
                            values: [String],
                            body: Node) async throws -> ExitStatus
    {
        var last = ExitStatus.success
        var iterations = 0
        loop: for value in values {
            try Task.checkCancellation()
            // Periodic cooperative yield. Mirrors the while-loop guard:
            // a `for i in $(seq 1 100); do echo $i; sleep 0.1; done | head -n 2`
            // pipeline can otherwise pin the producer's executor on the
            // single-CPU Android emulator long enough that the consumer
            // never gets a turn to read N lines and trigger upstream
            // cancellation.
            if iterations.isMultiple(of: 1024) {
                await Task.yield()
            }
            iterations += 1
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
    /// `case` patterns implicitly enable extglob; `nocasematch` enables
    /// case-insensitive comparison.
    private func armMatches(_ subject: String, armParts: [Node]) async throws -> Bool {
        let opts = GlobOptions(
            extglob: true,
            nocase:  shoptOptions["nocasematch"] == true)
        for node in armParts {
            guard case .pattern(let patterns) = node.kind else { continue }
            for sub in patterns {
                if case .reservedWord = sub.kind { continue }
                let expanded = try await expand(word: sub)
                if GlobMatcher.match(pattern: expanded, string: subject,
                                     options: opts) {
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
    ///
    /// `exit N` inside the subshell terminates only the subshell — the
    /// status is observable via `$?` in the parent. We catch the
    /// ``ShellExit`` sentinel here so it doesn't unwind the parent run.
    private func executeSubshellGroup(list: [Node]) async throws -> ExitStatus {
        // `copy()` is the single source of truth for what propagates
        // into a subshell — adding a new shell-scoped option means
        // updating that one method, never this code.
        let sub = copy()
        var last = ExitStatus.success
        do {
            try await sub.withCurrent {
                for node in list {
                    if case .reservedWord = node.kind { continue }
                    last = try await sub.execute(node)
                    sub.lastExitStatus = last
                }
            }
        } catch let exit as ShellExit {
            // Subshell-scoped exit: capture the status and let the
            // parent see it as `$?` without terminating its own run.
            last = exit.status
        } catch let signal as LoopControlSignal {
            // `(break)` / `(continue)` inside a subshell must NOT
            // unwind the parent's enclosing loop — bash treats loop
            // state as not crossing the subshell boundary.
            // `copy()` resets `loopDepth` to 0 in `sub`, so the
            // signal that escaped here is by definition stray. Warn
            // (matching the top-level stray-break behaviour) and
            // return success from the subshell.
            sub.warnStrayLoopControl(signal)
            last = .success
        }
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
