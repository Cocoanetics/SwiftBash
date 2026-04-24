import Foundation
import BashSyntax

extension Shell {

    // MARK: Public entry points

    /// Parse and execute a bash source string. Returns the exit status of
    /// the last command run (or `.success` if the input was empty).
    @discardableResult
    public func run(_ source: String) throws -> ExitStatus {
        let parts = try BashSyntax.parse(source)
        return try run(parts, source: source)
    }

    /// Execute an array of pre-parsed top-level nodes against `source`.
    @discardableResult
    public func run(_ parts: [Node], source: String) throws -> ExitStatus {
        let saved = currentSource
        currentSource = source
        defer { currentSource = saved }

        do {
            var last = ExitStatus.success
            for node in parts {
                last = try execute(node)
                lastExitStatus = last
            }
            return last
        } catch let exit as ShellExit {
            lastExitStatus = exit.status
            return exit.status
        }
    }

    // MARK: AST dispatch

    func execute(_ node: Node) throws -> ExitStatus {
        switch node.kind {
        case .command(let parts):
            return try executeSimpleCommand(parts: parts)

        case .list(let parts):
            return try executeList(parts: parts)

        case .pipeline:
            throw BashInterpreterError.unimplemented("pipelines (not yet supported in the builtins-only skeleton)")

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
                    return try executeIf(parts: parts)
                case .whileCommand(let parts):
                    return try executeWhileLike(parts: parts, invert: false)
                case .untilCommand(let parts):
                    return try executeWhileLike(parts: parts, invert: true)
                case .forCommand(let parts):
                    return try executeFor(parts: parts)
                case .caseCommand(let parts):
                    return try executeCase(parts: parts)
                default:
                    break
                }
            }
            // `{ … ; }` and `( … )` both arrive here with the body wrapped
            // between two reservedWord nodes. We execute non-reservedWord
            // members in order; subshells don't get env isolation yet.
            return try executeGroup(list: list)

        case .function:
            throw BashInterpreterError.unimplemented("function definitions")

        case .arithmeticCommand(let expr):
            return try runArithmeticCommand(expr)

        case .arithmeticSubstitution:
            // Only meaningful inside a word — handled by Shell+Expansion.
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
    private func executeList(parts: [Node]) throws -> ExitStatus {
        var status = ExitStatus.success
        var i = 0

        while i < parts.count {
            let node = parts[i]
            if case .operator(let op) = node.kind {
                switch op {
                case "&&":
                    if !status.isSuccess {
                        // Skip the next operand; resume at the operator *after* it.
                        i = skipRhsOfShortCircuit(parts: parts, from: i + 1)
                        continue
                    }
                case "||":
                    if status.isSuccess {
                        i = skipRhsOfShortCircuit(parts: parts, from: i + 1)
                        continue
                    }
                case ";", "\n":
                    break // simple separator; keep going
                case "&":
                    // Background: in the skeleton we run it in the foreground.
                    break
                default:
                    break
                }
                i += 1
                continue
            }
            status = try execute(node)
            lastExitStatus = status
            i += 1
        }

        return status
    }

    /// Given a list `parts` starting at a command node at index `from`,
    /// advance past that command's sub-tree. Since a list's children are
    /// already flat (command, op, command, op, …), this is simply
    /// "skip the command node".
    private func skipRhsOfShortCircuit(parts: [Node], from: Int) -> Int {
        guard from < parts.count else { return parts.count }
        return from + 1
    }

    // MARK: Simple commands

    /// Execute a `command` node — a sequence of assignments, words and
    /// redirections. In this skeleton we ignore redirections (throw) and
    /// dispatch only to registered built-ins.
    private func executeSimpleCommand(parts: [Node]) throws -> ExitStatus {
        // Partition into assignments, argv, and redirects.
        var assignments: [(String, String)] = []
        var argv: [String] = []
        var hasRedirect = false

        for part in parts {
            switch part.kind {
            case .assignment:
                let expanded = try expand(word: part)
                if let eq = expanded.firstIndex(of: "=") {
                    let name = String(expanded[..<eq])
                    let value = String(expanded[expanded.index(after: eq)...])
                    assignments.append((name, value))
                }
            case .word:
                argv.append(try expand(word: part))
            case .redirect:
                hasRedirect = true
            default:
                break
            }
        }

        if hasRedirect {
            throw BashInterpreterError.unimplemented(
                "redirection (builtins-only skeleton has no fd plumbing yet)")
        }

        // Standalone assignment: `X=1` with no argv.
        if argv.isEmpty {
            for (name, value) in assignments {
                environment[name] = value
            }
            return .success
        }

        // Assignments prefixed to a command are scoped to that command only.
        let restore = applyScopedAssignments(assignments)
        defer { restore() }

        guard let builtin = builtins[argv[0]] else {
            throw BashInterpreterError.commandNotFound(argv[0])
        }
        return try builtin.run(argv, shell: self)
    }

    /// Install `assignments` into the current environment, returning a
    /// closure that restores the prior values.
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
