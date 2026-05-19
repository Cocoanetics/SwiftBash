import Foundation
import Testing
@testable import BashInterpreter

/// Coverage for ``Shell/runIsolated(_:)`` / ``Shell/runCapturingIsolated(_:)``
/// — the "each call is its own bash process invocation" entry point.
///
/// The companion ``Shell/run(_:)`` path keeps REPL semantics (state
/// propagates so `source` / `eval` / profile loading work). Tests for
/// that contract live in `BuiltinsTests` and elsewhere.
@Suite(.timeLimit(.minutes(1))) struct RunIsolatedTests {

    // MARK: - issue #46 — state must not leak across runIsolated calls

    /// Working directory mutations made by the first call don't show
    /// up in the second. Both calls land on the same starting cwd.
    @Test func cwdDoesNotLeakAcrossRunIsolated() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"

        _ = try await cap.shell.runIsolated("cd /tmp")
        #expect(cap.shell.environment.workingDirectory == "/")

        let pwd = try await cap.shell.runCapturingIsolated("pwd")
        #expect(pwd.stdout == "/\n")
    }

    /// `export` in an isolated call doesn't propagate to the parent
    /// shell or to a later isolated call.
    @Test func exportedVarsDoNotLeakAcrossRunIsolated() async throws {
        let cap = CapturingShell()

        _ = try await cap.shell.runIsolated("export STATE_LEAK_TEST=leaked_value")
        #expect(cap.shell.environment["STATE_LEAK_TEST"] == nil)

        let second = try await cap.shell.runCapturingIsolated(
            #"echo "STATE_LEAK_TEST=${STATE_LEAK_TEST-unset}""#)
        #expect(second.stdout == "STATE_LEAK_TEST=unset\n")
    }

    /// A `trap … EXIT` registered in the first invocation must NOT
    /// be visible (or fire again) in the second. The trap still fires
    /// once at the end of its own invocation, so anything it writes
    /// to the filesystem is observable — that's correct EXIT semantics,
    /// matching real bash.
    @Test func exitTrapDoesNotLeakAcrossRunIsolated() async throws {
        let cap = CapturingShell()

        let first = try await cap.shell.runCapturingIsolated(
            "trap 'echo trap_fired' EXIT")
        // Trap fires when the isolated invocation ends.
        #expect(first.stdout == "trap_fired\n")
        // … but the parent shell has no leftover trap.
        #expect(cap.shell.traps["EXIT"] == nil)

        let second = try await cap.shell.runCapturingIsolated(
            #"echo "TRAP=$(trap -p EXIT)""#)
        // Second invocation sees no trap from the first.
        #expect(second.stdout == "TRAP=\n")
    }

    /// `set -e` in the first invocation must not stick to the parent
    /// (it's a per-process flag in real bash).
    @Test func setOptionsDoNotLeakAcrossRunIsolated() async throws {
        let cap = CapturingShell()

        _ = try await cap.shell.runIsolated("set -e")
        #expect(cap.shell.errexit == false)

        _ = try await cap.shell.runIsolated("set -u")
        #expect(cap.shell.nounset == false)
    }

    /// Function definitions made in one invocation don't carry into the
    /// next — each is its own shell.
    @Test func functionDefinitionsDoNotLeakAcrossRunIsolated() async throws {
        let cap = CapturingShell()

        _ = try await cap.shell.runIsolated("greet() { echo hi; }")

        let result = try await cap.shell.runCapturingIsolated("greet")
        #expect(result.exitStatus == ExitStatus(127))
        #expect(result.stderr.contains("greet"))
    }

    // MARK: - parent-shell state IS visible inside an isolated run

    /// Variables set on the parent shell before the call are visible
    /// inside the isolated run (copy semantics, not "blank slate").
    @Test func parentEnvVisibleInsideRunIsolated() async throws {
        let cap = CapturingShell()
        cap.shell.environment["GREETING"] = "hello"

        let result = try await cap.shell.runCapturingIsolated("echo $GREETING")
        #expect(result.stdout == "hello\n")
    }

    /// Filesystem and process table are shared by reference across an
    /// isolated invocation, so a file the run writes is visible to the
    /// next call. Only the in-memory shell state (env, traps, cwd) is
    /// confined to the subshell.
    ///
    /// Uses `NSTemporaryDirectory()` rather than `/tmp` so the test
    /// runs on Windows too (where `/tmp` doesn't exist).
    @Test func fileSystemSideEffectsPropagateAcrossRunIsolated() async throws {
        let cap = CapturingShell()
        let marker = NSTemporaryDirectory()
            + "swift-bash-runIsolated-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker) }

        _ = try await cap.shell.runIsolated("echo hi > '\(marker)'")

        let check = try await cap.shell.runCapturingIsolated(
            "[ -f '\(marker)' ] && echo present || echo missing")
        #expect(check.stdout == "present\n")
    }

    /// The parent shell's `interactive` flag (iBash-style REPL
    /// formatting: drop `: line N:` from diagnostics) must carry into
    /// the isolated subshell. Without this an embedder that switches
    /// its captured path from `runCapturing` to `runCapturingIsolated`
    /// would suddenly see `iBash: line 1: foo: command not found`
    /// instead of `iBash: foo: command not found`.
    @Test func interactiveFlagPropagatesIntoRunIsolated() async throws {
        let cap = CapturingShell()
        cap.shell.scriptName = "iBash"
        cap.shell.interactive = true

        let result = try await cap.shell.runCapturingIsolated("nosuchcommand")
        #expect(result.stderr == "iBash: nosuchcommand: command not found\n")
        // Parent stayed interactive — sanity check the flag itself
        // didn't leak the wrong direction either.
        #expect(cap.shell.interactive == true)
    }

    // MARK: - persistent run() still propagates (regression guard)

    /// Sanity check that the persistent ``run(_:)`` path keeps its
    /// REPL contract — exports persist for the next ``run(_:)`` call
    /// on the same shell.
    @Test func runStillPropagatesStateByDesign() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("export PERSIST_VAR=persistent")
        #expect(cap.shell.environment["PERSIST_VAR"] == "persistent")
    }
}
