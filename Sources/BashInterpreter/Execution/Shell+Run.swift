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
            if !redirects.isEmpty {
                throw BashInterpreterError.unimplemented(
                    "redirections on compound commands")
            }
            if list.count == 1 {
                switch list[0].kind {
                case .arithmeticCommand(let expr):
                    return try runArithmeticCommand(expr)
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

        case .function:
            throw BashInterpreterError.unimplemented("function definitions")

        case .arithmeticCommand(let expr):
            return try runArithmeticCommand(expr)

        case .arithmeticSubstitution:
            throw BashInterpreterError.unimplemented(
                "arithmetic substitution used outside a word")

        case .operator, .pipe, .reservedWord, .redirect,
             .word, .assignment, .parameter, .tilde, .heredoc,
             .commandSubstitution, .processSubstitution,
             .ifCommand, .whileCommand, .untilCommand, .forCommand,
             .caseCommand, .pattern, .unimplemented:
            throw BashInterpreterError.unimplemented(
                "top-level node kind: \(node.kindName)")
        }
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
        var assignments: [(String, String)] = []
        var argv: [String] = []
        var hasRedirect = false

        for part in parts {
            switch part.kind {
            case .assignment:
                let expanded = try await expand(word: part)
                if let eq = expanded.firstIndex(of: "=") {
                    let name = String(expanded[..<eq])
                    let value = String(expanded[expanded.index(after: eq)...])
                    assignments.append((name, value))
                }
            case .word:
                argv.append(try await expand(word: part))
            case .redirect:
                hasRedirect = true
            default:
                break
            }
        }

        if hasRedirect {
            throw BashInterpreterError.unimplemented(
                "redirection (no fd plumbing yet)")
        }

        if argv.isEmpty {
            for (name, value) in assignments {
                environment[name] = value
            }
            return .success
        }

        let restore = applyScopedAssignments(assignments)
        defer { restore() }

        guard let command = commands[argv[0]] else {
            throw BashInterpreterError.commandNotFound(argv[0])
        }
        return try await command.run(argv, shell: self)
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
