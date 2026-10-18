import Foundation

extension Shell {

    /// A ``copy()`` for a subshell of this shell — `( … )`, `$(…)`, a
    /// pipeline stage, an `&` job — rather than a new `bash` process.
    /// Inside a function it stays inside that function, like bash's
    /// fork: `local` works, and `return` ends the subshell (whoever
    /// runs it catches the ``ReturnSignal``).
    func subshell() -> Self {
        let sub = copy()
        // It runs inside this shell's run: an `eval` / `source` / trap
        // in it isn't the outermost run, so its `exit` reaches whoever
        // runs the subshell, and the parent's EXIT trap doesn't fire.
        sub.runDepth = 1
        // Where `set -e` is ignored (an `if` test, `&&` / `||`, `!`),
        // it stays ignored inside: `( false; echo kept ) || :` prints.
        sub.errexitGuard = errexitGuard
        // A trap that's running stays running: `$(…)` in a DEBUG or ERR
        // trap's body mustn't fire that trap again, recursively. The
        // subshell's own EXIT trap is separate (see `exitSubshell`).
        sub.runningTraps = runningTraps.subtracting(["EXIT"])
        // Mid-way through `-abc`, a subshell's `getopts` reads on from
        // where ours stopped.
        sub.getoptsCharIndex = getoptsCharIndex
        if functionCallDepth > 0 {
            sub.functionCallDepth = functionCallDepth
            sub.localVarStack = [[]]
        }
        // Bash resets these traps in a subshell: the parent's EXIT trap
        // doesn't fire when the subshell ends, nor its ERR trap on a
        // failure inside. `trap -p` still lists them.
        sub.inheritedTraps = inheritedTraps
        for name in Self.subshellResetTraps {
            if let body = sub.traps.removeValue(forKey: name) {
                sub.inheritedTraps[name] = body
            }
        }
        return sub
    }

    private static let subshellResetTraps = ["EXIT", "ERR", "DEBUG", "RETURN"]

    /// A ``copy()`` for a new process — `bash script`, `./script` — that
    /// keeps the environment and options but no traps, which `exec`
    /// resets.
    func childProcess() -> Self {
        let child = copy()
        child.traps = [:]
        child.inheritedTraps = [:]
        return child
    }

    /// End this subshell the way bash does: run the EXIT trap it set,
    /// if any. Returns the subshell's final status — an `exit N` in
    /// the trap overrides `status`.
    func exitSubshell(_ status: ExitStatus) async -> ExitStatus {
        guard let body = traps["EXIT"], !runningTraps.contains("EXIT") else {
            return status
        }
        runningTraps.insert("EXIT")
        defer { runningTraps.remove("EXIT") }
        lastExitStatus = status
        do {
            _ = try await run(body)
        } catch let exit as ShellExit {
            return exit.status
        } catch {}
        return status
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
        // A capture isn't a terminal: `$(ls)` lists one name per line.
        // A `>(cmd)` consumer writes to our own stdout and keeps its
        // terminal flag.
        if sink !== stdout { sub.stdoutIsTTY = false }
        sub.stdout = sink
        if let input {
            sub.stdin = input
            sub.stdinIsTTY = false
        }
        let status: ExitStatus
        do {
            status = try await sub.withCurrent { try await body(sub) }
        } catch let exit as ShellExit {
            status = exit.status
        } catch let ret as ReturnSignal {
            status = ret.status
        } catch is LoopControlSignal {
            // `v=$(break)` inside a loop quietly ends just the
            // substitution. (Outside any loop, `break` itself warns.)
            status = .success
        }
        return await sub.exitSubshell(status)
    }
}
