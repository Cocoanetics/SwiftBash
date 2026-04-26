import Foundation
import BashSyntax

extension Shell {

    // MARK: Public entry points

    /// Parse and execute a bash source string. Returns the exit status of
    /// the last command run (or `.success` if the input was empty).
    @discardableResult
    public func run(_ source: String) async throws -> ExitStatus {
        let parts = try BashSyntax.parse(source)
        return try await run(parts, source: source)
    }

    /// Execute an array of pre-parsed top-level nodes against `source`.
    @discardableResult
    public func run(_ parts: [Node], source: String) async throws -> ExitStatus {
        let saved = currentSource
        currentSource = source
        defer { currentSource = saved }

        let result: ExitStatus
        do {
            var last = ExitStatus.success
            for node in parts {
                do {
                    last = try await execute(node)
                    lastExitStatus = last
                } catch let signal as LoopControlSignal {
                    // Stray break/continue at top level — warn and
                    // continue with the next part.
                    warnStrayLoopControl(signal)
                    last = .success
                    lastExitStatus = last
                }
                // Top-level errexit: each statement is its own
                // node, so executeList's per-list check doesn't see
                // a sequence that crosses statement boundaries.
                let suppressed = skipNextErrexitCheck
                skipNextErrexitCheck = false
                if !last.isSuccess, errexitGuard == 0, !suppressed {
                    try await fireErrTrap()
                    if errexit { throw ShellExit(status: last) }
                }
            }
            result = last
        } catch let exit as ShellExit {
            lastExitStatus = exit.status
            result = exit.status
        }
        // EXIT trap fires once when the run finishes — whether through
        // normal completion, exit, or errexit.
        if let body = traps["EXIT"], !runningTraps.contains("EXIT") {
            runningTraps.insert("EXIT")
            do { _ = try await self.run(body) } catch {}
            runningTraps.remove("EXIT")
        }
        lastExitStatus = result
        return result
    }

    // MARK: AST dispatch

    func execute(_ node: Node) async throws -> ExitStatus {
        switch node.kind {
        case .command(let parts):
            return try await executeSimpleCommand(parts: parts)

        case .list(let parts):
            return try await executeList(parts: parts)

        case .pipeline(let parts):
            return try await executePipeline(parts: parts)

        case .compound(let list, let redirects):
            let procSubFrame = pendingProcessSubs.count
            let restore = try await applyRedirects(redirects)
            let result: ExitStatus
            do {
                result = try await runCompoundBody(list: list)
            } catch {
                restore()
                await drainProcessSubs(from: procSubFrame)
                throw error
            }
            restore()
            await drainProcessSubs(from: procSubFrame)
            return result

        case .function(let nameNode, let body, _):
            let name = try await expand(word: nameNode)
            commands[name] = FunctionCommand(
                name: name,
                body: body,
                definitionSource: currentSource)
            return .success

        case .arithmeticCommand(let expr):
            return try await runArithmeticCommand(expr)

        case .arithmeticSubstitution:
            throw BashInterpreterError.unimplemented(
                "arithmetic substitution used outside a word")

        case .conditional(let parts):
            return try await executeConditional(parts: parts)

        case .arrayAssignment:
            // The parser always wraps array assignments inside a
            // `.command(parts: [.arrayAssignment])`, so we route
            // through `executeSimpleCommand` which handles the
            // assignment alongside any words/redirects on the line.
            return try await executeSimpleCommand(parts: [node])

        case .operator, .pipe, .reservedWord, .redirect,
             .word, .assignment, .parameter, .tilde, .heredoc,
             .commandSubstitution, .processSubstitution,
             .ifCommand, .whileCommand, .untilCommand, .forCommand,
             .cStyleForCommand,
             .caseCommand, .pattern, .unimplemented:
            throw BashInterpreterError.unimplemented(
                "top-level node kind: \(node.kindName)")
        }
    }

    /// Dispatch the body of a `.compound` node — extracted so the
    /// caller can wrap redirects and process-sub draining around it.
    private func runCompoundBody(list: [Node]) async throws -> ExitStatus {
        if list.count == 1 {
            switch list[0].kind {
            case .arithmeticCommand(let expr):
                return try await runArithmeticCommand(expr)
            case .ifCommand(let parts):
                return try await executeIf(parts: parts)
            case .whileCommand(let parts):
                return try await executeWhileLike(parts: parts, invert: false)
            case .untilCommand(let parts):
                return try await executeWhileLike(parts: parts, invert: true)
            case .forCommand(let parts):
                return try await executeFor(parts: parts)
            case .cStyleForCommand(let i, let c, let u, let body):
                return try await executeCStyleFor(initExpr: i, condExpr: c,
                                                  updateExpr: u, body: body)
            case .caseCommand(let parts):
                return try await executeCase(parts: parts)
            default:
                break
            }
        }
        return try await executeGroup(list: list)
    }

    // MARK: Lists

    /// Execute a `list` node — a sequence of commands separated by `&&`,
    /// `||`, `;` or `\n`. Honours short-circuit for `&&`/`||`.
    func executeList(parts: [Node]) async throws -> ExitStatus {
        var status = ExitStatus.success
        var i = 0

        while i < parts.count {
            let node = parts[i]
            if case .operator(let op) = node.kind {
                switch op {
                case "&&":
                    if !status.isSuccess {
                        i = skipRhsOfShortCircuit(parts: parts, from: i + 1)
                        // Bash exempts a chain's final non-zero status
                        // from errexit when the failure happened on an
                        // already-guarded sub-command (the LHS of an
                        // `&&` we just short-circuited).
                        skipNextErrexitCheck = true
                        continue
                    }
                case "||":
                    if status.isSuccess {
                        i = skipRhsOfShortCircuit(parts: parts, from: i + 1)
                        continue
                    }
                case ";", "\n", "&":
                    break
                default:
                    break
                }
                i += 1
                continue
            }
            // Bash's errexit rule: a failing command does NOT trigger
            // errexit if it's the LHS of `&&`/`||`. Look ahead one
            // operator to detect that and run the command under a
            // guard so its exit doesn't take down the whole script.
            let isGuardedByChain = isGuardedByLogicalChain(parts: parts, from: i + 1)
            if isGuardedByChain { errexitGuard += 1 }
            do {
                status = try await execute(node)
                lastExitStatus = status
            } catch let signal as LoopControlSignal {
                if isGuardedByChain { errexitGuard -= 1 }
                if loopDepth > 0 { throw signal }
                warnStrayLoopControl(signal)
                status = .success
                i += 1
                continue
            } catch {
                if isGuardedByChain { errexitGuard -= 1 }
                throw error
            }
            if isGuardedByChain { errexitGuard -= 1 }

            // ERR trap fires after a command fails (in a non-guarded
            // context — same exemptions as errexit).
            let suppressed = skipNextErrexitCheck
            skipNextErrexitCheck = false
            if !status.isSuccess, errexitGuard == 0,
               !suppressed, !isGuardedByChain
            {
                try await fireErrTrap()
                if errexit { throw ShellExit(status: status) }
            }
            i += 1
        }

        return status
    }

    /// Look at the next operator (skipping no-ops like `;` / `\n`) and
    /// return `true` iff it's `&&` or `||` — meaning the just-ran
    /// command's failure is "checked" by the chain and shouldn't fire
    /// errexit.
    private func isGuardedByLogicalChain(parts: [Node], from: Int) -> Bool {
        var j = from
        while j < parts.count {
            guard case .operator(let op) = parts[j].kind else { return false }
            switch op {
            case "&&", "||": return true
            case ";", "\n":  j += 1; continue
            default:         return false
            }
        }
        return false
    }

    private func skipRhsOfShortCircuit(parts: [Node], from: Int) -> Int {
        guard from < parts.count else { return parts.count }
        return from + 1
    }

    // MARK: Trap firing

    /// Fire the `ERR` trap if registered. Re-entrancy is guarded so a
    /// failing command inside the trap body doesn't recurse.
    func fireErrTrap() async throws {
        guard let body = traps["ERR"], !runningTraps.contains("ERR") else { return }
        runningTraps.insert("ERR")
        defer { runningTraps.remove("ERR") }
        // Suppress errexit while running the trap so a failure
        // inside doesn't trigger an immediate exit.
        errexitGuard += 1
        defer { errexitGuard -= 1 }
        do { _ = try await self.run(body) } catch is ShellExit { /* let it through */ }
    }

    /// Fire the `DEBUG` trap if registered. Called before each simple
    /// command. The trap body is evaluated in the current shell.
    func fireDebugTrap() async throws {
        guard let body = traps["DEBUG"], !runningTraps.contains("DEBUG") else { return }
        runningTraps.insert("DEBUG")
        defer { runningTraps.remove("DEBUG") }
        errexitGuard += 1
        defer { errexitGuard -= 1 }
        do { _ = try await self.run(body) } catch is ShellExit { /* swallow */ }
    }

    // MARK: Simple commands

    /// Execute a `command` node — a sequence of assignments, words and
    /// redirections. Redirections still throw `.unimplemented`; dispatch
    /// falls through to the registered command registry.
    private func executeSimpleCommand(parts: [Node]) async throws -> ExitStatus {
        try await fireDebugTrap()
        let procSubFrame = pendingProcessSubs.count
        var assignments: [(String, String)] = []
        var wordFragments: [(node: Node, fragments: [WordFragment])] = []
        var redirects: [Node] = []

        // Bash word expansion order:
        // 1. Substitution (parameter / command / arithmetic) on
        //    assignment values AND command words — *all using the
        //    pre-prefix env*. This matters: `X=outer; X=inner echo $X`
        //    must print "outer" because $X's substitution runs before
        //    the prefix assignment is in scope.
        // 2. Apply prefix assignments to the shell env (scoped to the
        //    duration of the command).
        // 3. Field splitting on the substituted command words — uses
        //    the *new* `$IFS`, so `IFS=":" cmd $X` does split on `:`.
        // 4. Pathname expansion (globbing).
        // 5. Run the command.
        // 6. Restore.
        do {
            for part in parts {
                switch part.kind {
                case .assignment:
                    let expanded = try await expand(word: part)
                    if let eq = expanded.firstIndex(of: "=") {
                        let lhs = String(expanded[..<eq])
                        let value = String(
                            expanded[expanded.index(after: eq)...])
                        // Element form: `arr[N]=value` updates the
                        // array in place rather than introducing a
                        // scalar named `arr[N]`.
                        if applyArrayElementAssignmentIfApplicable(
                            lhs: lhs, value: value)
                        {
                            continue
                        }
                        assignments.append((lhs, value))
                    }
                case .arrayAssignment(let name, let items, let append):
                    // `name=(item …)` and `name+=(item …)`. Evaluate
                    // items now, store permanently. Prefix-form
                    // `arr=(a b) cmd` is rare; we don't scope it.
                    var values: [String] = []
                    for item in items {
                        values.append(try await expand(word: item))
                    }
                    if append {
                        var existing = environment.arrays[name] ?? BashArray()
                        existing.append(values)
                        environment.arrays[name] = existing
                    } else {
                        environment.arrays[name] = BashArray(dense: values)
                    }
                    environment.variables.removeValue(forKey: name)
                case .word:
                    let frags = try await collectArgFragments(word: part)
                    wordFragments.append((part, frags))
                case .redirect:
                    redirects.append(part)
                default:
                    break
                }
            }
        } catch {
            await drainProcessSubs(from: procSubFrame)
            throw error
        }

        // Step 2: apply prefix assignments. Scope is restored at the
        // end unless the command turns out to be empty (assignments
        // stay permanent in that case, matching bash).
        var savedScope: [(String, String?)] = []
        for (name, value) in assignments {
            savedScope.append((name, environment[name]))
            environment[name] = value
        }
        func restoreScope() {
            for (name, prior) in savedScope.reversed() {
                environment[name] = prior
            }
            savedScope.removeAll()
        }

        let restoreRedirects: @Sendable () -> Void
        do {
            restoreRedirects = try await applyRedirects(redirects)
        } catch {
            restoreScope()
            await drainProcessSubs(from: procSubFrame)
            throw error
        }

        // Step 3 + 4: field splitting (uses scoped $IFS), brace
        // expansion, then globbing. Brace expansion is gated on the
        // word's source so quoted braces (`'{a,b}'`, JSON literals)
        // pass through untouched.
        var argv: [String] = []
        do {
            for (node, frags) in wordFragments {
                let assembled = assembleArgs(frags)
                let braced = braceExpandIfWordHasUnquotedBraces(
                    node: node, args: assembled)
                for arg in braced {
                    argv.append(contentsOf: try await globExpand(
                        arg, originalWord: node))
                }
            }
        } catch {
            restoreRedirects()
            restoreScope()
            await drainProcessSubs(from: procSubFrame)
            throw error
        }

        // No command word → keep assignments permanent.
        if argv.isEmpty {
            savedScope.removeAll()
            restoreRedirects()
            await drainProcessSubs(from: procSubFrame)
            return .success
        }

        let result: ExitStatus
        do {
            guard let command = commands[argv[0]] else {
                // Match bash: report to stderr, return 127, do not abort
                // the script. Callers chain on `cmd || …`, `command -v`,
                // etc., and rely on $? observability.
                stderr("\(argv[0]): command not found\n")
                restoreScope()
                restoreRedirects()
                await drainProcessSubs(from: procSubFrame)
                return ExitStatus(127)
            }
            result = try await command.run(argv, shell: self)
        } catch {
            restoreScope()
            restoreRedirects()
            await drainProcessSubs(from: procSubFrame)
            throw error
        }
        restoreScope()
        restoreRedirects()
        await drainProcessSubs(from: procSubFrame)
        return result
    }

    /// Handle `arr[N]=value` element assignment if `lhs` looks like
    /// `name[subscript]`. Returns `true` when the form was matched
    /// and applied (caller should *not* fall through to scalar
    /// assignment), `false` otherwise.
    private func applyArrayElementAssignmentIfApplicable(
        lhs: String, value: String
    ) -> Bool {
        guard let lb = lhs.firstIndex(of: "["), lhs.last == "]" else {
            return false
        }
        let arrName = String(lhs[..<lb])
        let after = lhs.index(after: lb)
        let last = lhs.index(before: lhs.endIndex)
        let sub = String(lhs[after..<last])

        // Associative dispatch: if `name` was previously declared
        // with `declare -A`, the subscript is a string key.
        if environment.associativeArrays[arrName] != nil {
            environment.associativeArrays[arrName]?[sub] = value
            return true
        }

        // Indexed array element assignment — subscript must be an
        // integer literal (arithmetic-evaluating subscripts are a
        // stretch goal).
        guard let n = Int(sub), n >= 0 else { return false }
        var array = environment.arrays[arrName] ?? BashArray()
        array[n] = value
        environment.arrays[arrName] = array
        environment.variables.removeValue(forKey: arrName)
        return true
    }

    /// Clean up process substitutions allocated by the just-finished
    /// command. For `<(cmd)`, just delete the temp file. For `>(cmd)`,
    /// feed the temp file's contents to the consumer command first,
    /// then delete.
    func drainProcessSubs(from frameStart: Int) async {
        guard pendingProcessSubs.count > frameStart else { return }
        let frame = Array(pendingProcessSubs[frameStart...])
        pendingProcessSubs.removeSubrange(frameStart...)

        for sub in frame {
            switch sub.kind {
            case .input:
                try? await fileSystem.remove(sub.path, recursive: false)
            case .output:
                if let consumer = sub.consumer {
                    let captured =
                        (try? await fileSystem.readData(sub.path)) ?? Data()
                    let savedStdin = stdin
                    stdin = .data(captured)
                    _ = try? await execute(consumer)
                    stdin = savedStdin
                }
                try? await fileSystem.remove(sub.path, recursive: false)
            }
        }
    }

    private func applyScopedAssignments(_ assignments: [(String, String)]) -> () -> Void {
        guard !assignments.isEmpty else { return {} }
        var priors: [(String, String?)] = []
        for (k, v) in assignments {
            priors.append((k, environment[k]))
            environment[k] = v
        }
        return { [weak self] in
            guard let self else { return }
            for (k, prior) in priors {
                self.environment[k] = prior
            }
        }
    }
}
