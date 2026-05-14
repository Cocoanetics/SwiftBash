import Foundation
import BashSyntax

extension Shell {

    /// Names of bash's "assignment built-ins" — commands whose argv
    /// elements that look like `name=value` are processed as proper
    /// declarations by the command itself, *not* treated as scoped
    /// prefix assignments. Used by ``executeSimpleCommand`` to route
    /// assignment-words to argv when the command word matches.
    static let assignmentBuiltinNames: Set<String> = [
        "declare", "typeset", "local", "readonly", "export",
    ]

    /// Parse a `[key]=value` pair as it appears inside an
    /// associative-array literal `declare -A m=([k]=v …)`. Returns
    /// `(key, value)` or `nil` when the input doesn't have that shape.
    func parseKeyedAssignment(_ raw: String) -> (key: String, value: String)? {
        // Permit empty values (`[k]=`) and values containing further
        // `=` (`[url]=https://x?a=b`).
        guard raw.hasPrefix("["),
              let closeBracket = raw.firstIndex(of: "]"),
              raw.index(after: closeBracket) < raw.endIndex,
              raw[raw.index(after: closeBracket)] == "="
        else { return nil }
        let key = String(raw[raw.index(after: raw.startIndex)..<closeBracket])
        let valueStart = raw.index(closeBracket, offsetBy: 2)
        let value = String(raw[valueStart...])
        return (key, value)
    }

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
        // Bind self as the task-local current shell for the duration
        // of the run. Subshells, pipeline stages, traps, and any
        // command body all read shell state via `Shell.bashCurrent`.
        return try await withCurrent {
            try await runImpl(parts, source: source)
        }
    }

    private func runImpl(_ parts: [Node],
                         source: String) async throws -> ExitStatus
    {
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
            // `cmd &`: peek the next operator. If it's `&`, spawn the
            // command as a virtual background job in the process table,
            // set `$!` to the new PID, and don't await — the shell
            // moves on immediately with status = 0.
            if isBackgroundedAt(parts: parts, from: i + 1) {
                let pid = await spawnBackground(node: node)
                environment["!"] = "\(pid)"
                status = .success
                lastExitStatus = status
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

    /// `true` if the operator at `from` is `&` — meaning the command
    /// at `from - 1` should run as a background job.
    private func isBackgroundedAt(parts: [Node], from: Int) -> Bool {
        guard from < parts.count,
              case .operator("&") = parts[from].kind
        else { return false }
        return true
    }

    /// Spawn `node` in a fresh subshell on the process table, return
    /// the assigned virtual PID. Errors thrown by the body are caught
    /// inside the Task and recorded as the entry's exit state — they
    /// never propagate back to the parent here.
    private func spawnBackground(node: Node) async -> Int32 {
        let sub = copy()
        let label = nodeCommandLabel(node)
        return await processTable.spawn(command: label) {
            do {
                return try await sub.withCurrent {
                    do {
                        return try await sub.execute(node)
                    } catch is ShellExit {
                        // `exit N` inside a background job ends the
                        // JOB, not the parent shell.
                        return sub.lastExitStatus
                    }
                }
            } catch is CancellationError {
                // The Task got `kill`'d. Return cleanly with the
                // bash-style 128 + SIGTERM exit code so `wait $!`
                // sees 143 and the error doesn't leak past the table.
                return ExitStatus(143)
            }
        }
    }

    /// Cheap label for a node — what `ps` / `jobs` shows for the entry.
    /// Falls back to the source slice; gives `?` if there's nothing.
    private func nodeCommandLabel(_ node: Node) -> String {
        let chars = Array(currentSource)
        let lo = max(0, node.range.lowerBound)
        let hi = min(chars.count, node.range.upperBound)
        guard lo < hi else { return "?" }
        return String(chars[lo..<hi]).trimmingCharacters(in: .whitespaces)
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
        // Track which command we're dispatching so error messages can
        // include `script.sh: line N:` like bash does.
        let savedCommandRange = currentCommandRange
        if let first = parts.first {
            currentCommandRange = first.range
        }
        defer { currentCommandRange = savedCommandRange }
        // Full source span of the simple command (first-part start →
        // last-part end). The error-prefix range is intentionally
        // narrower (line of `parts.first`), but `set -v` needs the
        // whole statement so the trace echoes `echo hi`, not just
        // `echo`.
        let simpleCommandRange: Range<Int>? = {
            guard let first = parts.first?.range else { return nil }
            let upper = parts.last?.range.upperBound ?? first.upperBound
            return first.lowerBound..<max(first.upperBound, upper)
        }()

        let procSubFrame = pendingProcessSubs.count
        var assignments: [(String, String)] = []
        var wordFragments: [(node: Node, fragments: [WordFragment])] = []
        var redirects: [Node] = []

        // Pre-pass: locate the command word and decide whether it's an
        // "assignment built-in" (declare / typeset / local / readonly /
        // export). For those, parts after the command word that LOOK
        // like assignments (`x=1`, `arr=(…)`, `arr[i]=v`) are not
        // prefix assignments — they're arguments processed by the
        // built-in itself. Without this rule `declare x=1` would set
        // `x` only for `declare`'s own (no-op) duration.
        let commandWordIndex: Int? = {
            for (idx, part) in parts.enumerated() {
                if case .word = part.kind { return idx }
            }
            return nil
        }()
        let isAssignmentBuiltin: Bool = {
            guard let idx = commandWordIndex,
                  case .word = parts[idx].kind
            else { return false }
            // Look at the literal source text of the command word —
            // assignment built-ins are never reached via expansion in
            // realistic scripts, and we need this decision before any
            // expansion runs.
            let raw = String(parts[idx].source(from: currentSource))
            return Self.assignmentBuiltinNames.contains(raw)
        }()
        // For `declare -A name=(…)` the items inside `(…)` are
        // `[key]=value` pairs, not dense values. Detect the `-A` flag
        // by scanning the .word parts that follow the command word
        // and precede any arrayAssignment.
        let declareAssociativeMode: Bool = {
            guard isAssignmentBuiltin, let cmdIdx = commandWordIndex
            else { return false }
            for part in parts[(cmdIdx + 1)...] {
                if case .arrayAssignment = part.kind { break }
                if case .word = part.kind {
                    let raw = String(part.source(from: currentSource))
                    // Handle merged flags (`-Ar`, `-rA`).
                    if raw.hasPrefix("-"), !raw.hasPrefix("--"),
                       raw.contains("A")
                    {
                        return true
                    }
                }
            }
            return false
        }()

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
            for (idx, part) in parts.enumerated() {
                let pastCommandWord = commandWordIndex.map { idx > $0 } ?? false
                let routeAsArg = isAssignmentBuiltin && pastCommandWord
                switch part.kind {
                case .assignment:
                    let expanded = try await expand(word: part)
                    if routeAsArg {
                        // Hand the literal `name=value` string to the
                        // built-in as a regular argv element.
                        wordFragments.append((part, [.literal(expanded)]))
                        break
                    }
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
                    if routeAsArg && declareAssociativeMode {
                        // `declare -A m=([k1]=v1 [k2]=v2)` — items are
                        // keyed pairs. Drop into the associative table.
                        var dict = append
                            ? (environment.associativeArrays[name] ?? [:])
                            : [String: String]()
                        for raw in values {
                            if let (key, value) = parseKeyedAssignment(raw) {
                                dict[key] = value
                            }
                        }
                        environment.associativeArrays[name] = dict
                        environment.arrays.removeValue(forKey: name)
                        environment.variables.removeValue(forKey: name)
                        wordFragments.append((part, [.literal(name)]))
                        break
                    }
                    if append {
                        var existing = environment.arrays[name] ?? BashArray()
                        existing.append(values)
                        environment.arrays[name] = existing
                    } else {
                        environment.arrays[name] = BashArray(dense: values)
                    }
                    environment.variables.removeValue(forKey: name)
                    // Even when this is `declare -a a=(…)` we don't
                    // also pass the value through argv — the array is
                    // registered above; declare's only remaining job
                    // is the type flag, which it does with an empty
                    // value field on the matching `name` arg.
                    if routeAsArg {
                        wordFragments.append((part, [.literal(name)]))
                    }
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
        } catch let fsError as FileSystemError {
            // A failed `>file` / `<file` / `>>file` redirect (target
            // unreadable, parent missing, mount read-only) is a
            // per-command failure in real bash, NOT a fatal script
            // error. Print a bash-style diagnostic, restore the
            // partial scope, and return non-zero so the enclosing
            // list keeps running. Without this, `cd /tmp; echo x >
            // /examples/foo; echo done` would never print `done` —
            // the entire tool call aborted on the first redirect
            // failure.
            let target: String
            switch fsError {
            case .notFound(let p), .notADirectory(let p),
                 .isADirectory(let p), .alreadyExists(let p),
                 .permissionDenied(let p):
                target = p
            case .io(let m):
                target = m
            }
            stderr(
                "\(errorLocationPrefix())\(target): \(fsError.shellMessage())\n")
            restoreScope()
            await drainProcessSubs(from: procSubFrame)
            return ExitStatus(1)
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

        // `set -v` / `set -o verbose` — echo the raw source slice of
        // the simple command to stderr before execution. Runs *here*
        // (after we know we have a real command word) so empty
        // statements like a bare assignment block don't fire a
        // phantom blank trace line. Uses the full first-part →
        // last-part span so multi-word commands echo intact
        // (`echo hi`, not just `echo`).
        if verbose, let range = simpleCommandRange {
            let chars = Array(currentSource)
            let upper = min(range.upperBound, chars.count)
            if range.lowerBound < upper {
                stderr.write(
                    String(chars[range.lowerBound..<upper]) + "\n")
            }
        }
        // `set -x` / `set -o xtrace` — echo the resolved argv with
        // the `$PS4` prefix (default `"+ "`). Matches real bash's
        // post-expansion trace; pipelines and subshells inherit
        // `xtrace` through ``copy()`` so a `set -x` inside a script
        // traces every nested simple command.
        if xtrace {
            let ps4 = environment["PS4"] ?? "+ "
            stderr.write(ps4 + argv.joined(separator: " ") + "\n")
        }

        let result: ExitStatus
        do {
            if let command = commands[argv[0]] {
                result = try await command.run(argv)
            } else if let command = commandForCatalogPath(argv[0]) {
                // Absolute-path invocation of a registered command
                // — `/bin/bash --version`, `/usr/bin/env`, etc.
                // BinCatalogOverlay vends these as files but the
                // dispatcher only keys the registry by basename, so
                // without this branch the path resolution falls
                // through to the external-script try (which fails
                // because the synthetic stub has no shebang) and
                // surfaces as `command not found`. Rewrite argv[0]
                // to the basename so the command sees the canonical
                // invocation.
                var rewritten = argv
                rewritten[0] = (argv[0] as NSString).lastPathComponent
                result = try await command.run(rewritten)
            } else if let scriptResult =
                try await dispatchAsExternalScriptIfApplicable(argv: argv)
            {
                result = scriptResult
            } else {
                // Match bash: report to stderr (with `script:line:`
                // prefix), return 127, do not abort the script.
                stderr("\(errorLocationPrefix())\(argv[0]): command not found\n")
                restoreScope()
                restoreRedirects()
                await drainProcessSubs(from: procSubFrame)
                return ExitStatus(127)
            }
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
