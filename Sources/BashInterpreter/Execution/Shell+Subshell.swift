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
    ///
    /// - parameter commandSubstitution: `true` for `$(…)` and
    ///   `` `…` ``, which bash runs without `set -e` unless
    ///   `shopt -s inherit_errexit`; process substitutions keep it.
    func runSubshell(
        stdout sink: OutputSink,
        stdin input: InputSource? = nil,
        commandSubstitution: Bool = false,
        _ body: (Shell) async throws -> ExitStatus
    ) async throws -> ExitStatus {
        let sub = subshell()
        if commandSubstitution, shoptOptions["inherit_errexit"] != true {
            sub.errexit = false
        }
        // Unlike `( … )`, bash's substitutions keep the loop context:
        // `v=$(break)` in a loop ends just the substitution.
        sub.loopDepth = loopDepth
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
        } catch let signal as LoopControlSignal {
            // `v=$(break)` inside a loop quietly ends just the subshell;
            // outside any loop bash warns, as for a bare `break`.
            if loopDepth == 0 { sub.warnStrayLoopControl(signal) }
            return .success
        }
    }
}
