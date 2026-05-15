import Foundation
import BashSyntax

extension Shell {

    /// Apply a command's redirect nodes, returning a closure that
    /// restores the previous `stdin` / `stdout` / `stderr` and closes
    /// any file sinks that were opened. Left-to-right application
    /// matches bash's `cmd >a 2>&1` order semantics:
    ///
    /// - `cmd >out 2>&1` sends both streams to `out`.
    /// - `cmd 2>&1 >out` sends stdout to `out` but stderr inherits
    ///   whatever the caller's stdout was.
    ///
    /// Throws at setup time if a file can't be opened, or if a redirect
    /// kind isn't supported yet.
    func applyRedirects(_ redirects: [Node]) async throws -> @Sendable () -> Void {
        let savedStdin = stdin
        let savedStdout = stdout
        let savedStderr = stderr
        var openedSinks: [OutputSink] = []

        do {
            for redirNode in redirects {
                guard case .redirect(let input,
                                     let type,
                                     let output,
                                     let heredoc) = redirNode.kind
                else { continue }

                try await applyOne(input: input,
                                   type: type,
                                   output: output,
                                   heredoc: heredoc,
                                   openedSinks: &openedSinks)
            }
        } catch {
            // Roll back anything we did open so we don't leak file
            // handles when a *later* redirect in the same list fails.
            for sink in openedSinks { sink.finish() }
            stdin = savedStdin
            stdout = savedStdout
            stderr = savedStderr
            throw error
        }

        let captured = openedSinks
        return { [weak self] in
            for sink in captured { sink.finish() }
            guard let self else { return }
            self.stdin = savedStdin
            self.stdout = savedStdout
            self.stderr = savedStderr
        }
    }

    // Flat dispatch over redirect operators (`>`, `>>`, `<`, `<<`,
    // `<<-`, `<<<`, `>&`, `<&`); one case per operator.
    // swiftlint:disable:next cyclomatic_complexity
    private func applyOne(input: Int?,
                          type: String,
                          output: Node,
                          heredoc: Node?,
                          openedSinks: inout [OutputSink]) async throws {
        switch type {
        case ">":
            let target = try await expand(word: output)
            let sink = try await openOutputPath(target, append: false)
            openedSinks.append(sink)
            bind(outputSink: sink, toFd: input ?? 1)

        case ">>":
            let target = try await expand(word: output)
            let sink = try await openOutputPath(target, append: true)
            openedSinks.append(sink)
            bind(outputSink: sink, toFd: input ?? 1)

        case "<":
            let target = try await expand(word: output)
            stdin = try await openInputPath(target)

        case "<<", "<<-":
            // Heredoc. The parser captures the body as `.heredoc(value:)`.
            // For `<<-` the parser already stripped leading tabs from
            // each body line (and the closing-delimiter line) before
            // attaching the body, so this case can treat the two forms
            // identically.
            //
            // If the delimiter was *quoted* (`<<'EOF'`, `<<"EOF"`, or
            // `<<\EOF`) the body is fed verbatim; otherwise it's
            // expanded the same way the inside of a double-quoted
            // string is — `$VAR`, `${…}`, `$(…)`, `$((…))`, and
            // backtick command subs all fire.
            guard let heredocNode = heredoc,
                  case .heredoc(let body) = heredocNode.kind
            else {
                throw BashInterpreterError.unimplemented(
                    "heredoc without body")
            }
            if delimiterIsQuoted(output) {
                stdin = .string(body)
            } else {
                stdin = .string(try await expandHeredocBody(body))
            }

        case "<<<":
            // Here-string: feed `body + "\n"` as stdin. The body is
            // produced by normal word expansion, so `cat <<< $VAR`
            // and `cat <<< "hello $NAME"` both work.
            let body = try await expand(word: output)
            stdin = .string(body + "\n")

        case ">&":
            // fd duplication: `N>&M` points N at whatever M currently is.
            let rhs = try await expand(word: output)
            guard let targetFd = Int(rhs) else {
                // Bash also accepts `>&-` (close fd) and `>&path` forms;
                // not supporting those yet.
                throw BashInterpreterError.unimplemented(
                    "redirect operand not a file descriptor: \(rhs)")
            }
            let sourceFd = input ?? 1
            let donor = currentOutputSink(forFd: targetFd)
            bind(outputSink: donor, toFd: sourceFd)

        case "<&":
            // `<&N` duplicates an input fd. Only fd 0 is meaningful for
            // us — the shell only tracks `stdin`. Validate and no-op.
            let rhs = try await expand(word: output)
            guard let targetFd = Int(rhs), targetFd == 0 else {
                throw BashInterpreterError.unimplemented(
                    "input fd duplication from fd \(rhs)")
            }
            // stdin stays as-is; listed for completeness.

        default:
            throw BashInterpreterError.unimplemented(
                "redirect operator: \(type)")
        }
    }

    private func bind(outputSink sink: OutputSink, toFd descriptor: Int) {
        switch descriptor {
        case 1: stdout = sink
        case 2: stderr = sink
        default:
            // Higher fds (`3>file`, etc.) aren't tracked yet. Silently
            // ignore — most scripts only touch 1 and 2.
            break
        }
    }

    private func currentOutputSink(forFd descriptor: Int) -> OutputSink {
        switch descriptor {
        case 1: return stdout
        case 2: return stderr
        default: return stdout
        }
    }

    /// True when the heredoc delimiter word in source contained any
    /// quote (`'`, `"`) or backslash — bash's signal to skip body
    /// expansion. The parser strips quotes from the *value* but keeps
    /// them in the source range.
    private func delimiterIsQuoted(_ word: Node) -> Bool {
        let chars = Array(currentSource)
        let low = max(0, word.range.lowerBound)
        let high = min(chars.count, word.range.upperBound)
        for index in low..<high {
            let char = chars[index]
            if char == "'" || char == "\"" || char == "\\" { return true }
        }
        return false
    }
}
