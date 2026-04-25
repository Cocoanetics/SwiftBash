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
            }
            return last
        } catch let exit as ShellExit {
            lastExitStatus = exit.status
            return exit.status
        }
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
            do {
                status = try await execute(node)
                lastExitStatus = status
            } catch let signal as LoopControlSignal {
                if loopDepth > 0 { throw signal }
                warnStrayLoopControl(signal)
                status = .success
            }
            i += 1
        }

        return status
    }

    private func skipRhsOfShortCircuit(parts: [Node], from: Int) -> Int {
        guard from < parts.count else { return parts.count }
        return from + 1
    }

    // MARK: Simple commands

    /// Execute a `command` node — a sequence of assignments, words and
    /// redirections. Redirections still throw `.unimplemented`; dispatch
    /// falls through to the registered command registry.
    private func executeSimpleCommand(parts: [Node]) async throws -> ExitStatus {
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
                        let name = String(expanded[..<eq])
                        let value = String(expanded[expanded.index(after: eq)...])
                        assignments.append((name, value))
                    }
                case .arrayAssignment(let name, let items):
                    // `name=(item …)` — evaluate items now, store
                    // permanently. Prefix-form `arr=(a b) cmd` is
                    // rare; we don't model the scoped variant.
                    var values: [String] = []
                    for item in items {
                        values.append(try await expand(word: item))
                    }
                    environment.arrays[name] = values
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

        // Step 3 + 4: field splitting (uses scoped $IFS) then globbing.
        var argv: [String] = []
        do {
            for (node, frags) in wordFragments {
                for arg in assembleArgs(frags) {
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
                throw BashInterpreterError.commandNotFound(argv[0])
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
