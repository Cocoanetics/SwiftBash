import Foundation

extension Shell {

    /// A ``copy()`` for a subshell of this shell — `( … )`, `$(…)`, a
    /// pipeline stage, an `&` job — rather than a new `bash` process.
    /// Inside a function it stays inside that function, like bash's
    /// fork: `local` works, and `return` ends the subshell (whoever
    /// runs it catches the ``ReturnSignal``).
    func subshell() -> Self {
        let sub = copy()
        if functionCallDepth > 0 {
            sub.functionCallDepth = functionCallDepth
            sub.localVarStack = [[]]
        }
        return sub
    }

    /// Run `body` in a subshell — a ``subshell()`` of this shell, the way
    /// bash forks for `$(…)`, `` `…` ``, `<(…)` and `>(…)` — with its
    /// stdout going to `sink`. Assignments, `cd`, function definitions
    /// and `exit` stay inside: `exit N` (or `return N` in a function)
    /// ends just the subshell, and N is returned like any other status.
    func runSubshell(
        stdout sink: OutputSink,
        stdin input: InputSource? = nil,
        _ body: (Shell) async throws -> ExitStatus
    ) async throws -> ExitStatus {
        let sub = subshell()
        sub.stdout = sink
        // A capture isn't a terminal: `$(ls)` lists one name per line.
        sub.stdoutIsTTY = false
        if let input {
            sub.stdin = input
            sub.stdinIsTTY = false
        }
        do {
            return try await sub.withCurrent { try await body(sub) }
        } catch let exit as ShellExit {
            return exit.status
        } catch let ret as ReturnSignal {
            return ret.status
        } catch is LoopControlSignal {
            // `v=$(break)` inside a loop ends only the subshell; bash
            // doesn't warn here.
            return .success
        }
    }
}
