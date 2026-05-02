import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// End-to-end tests for `&` background execution and `wait`.
@Suite(.timeLimit(.minutes(1))) struct BackgroundJobTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func ampersandReturnsImmediately() async throws {
        let cap = makeShell()
        let started = Date()
        try await cap.shell.run("sleep 1 & echo done")
        let elapsed = Date().timeIntervalSince(started)
        // The `echo done` must run while the sleep is still going.
        #expect(elapsed < 0.5)
        #expect(cap.stdout.contains("done"))
    }

    @Test func waitBlocksUntilJobFinishes() async throws {
        let cap = makeShell()
        let started = Date()
        try await cap.shell.run("sleep 0.2 & wait; echo finished")
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.18,
                "wait should block until the sleep completes")
        #expect(cap.stdout.contains("finished"))
    }

    // Skipped on Android: the single-CPU emulator's cooperative
    // scheduler serialises the three Task.sleep timers far enough that
    // the elapsed-time assertion (< 0.6s for three 0.3s parallel
    // sleeps) is not reliable.
    #if !os(Android)
    @Test func parallelFanOutRunsConcurrently() async throws {
        let cap = makeShell()
        let started = Date()
        try await cap.shell.run("""
            sleep 0.3 &
            sleep 0.3 &
            sleep 0.3 &
            wait
            echo all-done
            """)
        let elapsed = Date().timeIntervalSince(started)
        // Three 300ms sleeps in parallel finish in ~300ms, not 900ms.
        #expect(elapsed < 0.6,
                "expected parallel execution, got \(elapsed)s")
        #expect(cap.stdout.contains("all-done"))
    }
    #endif

    @Test func dollarBangResolvesToLastSpawnedPid() async throws {
        let cap = makeShell()
        try await cap.shell.run("sleep 0.05 & echo \"pid=$!\"; wait")
        // Default starting PID is 1000.
        #expect(cap.stdout.contains("pid=1000"))
    }

    @Test func waitWithSpecificPidReturnsItsExitStatus() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            (exit 7) &
            wait $!
            echo "rc=$?"
            """)
        #expect(cap.stdout.contains("rc=7"))
    }

    @Test func waitWithNoArgsReturnsLastStatus() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            (exit 3) &
            wait
            echo "rc=$?"
            """)
        // `wait` (no args) returns the last awaited status; with one
        // backgrounded job, that's its exit status.
        #expect(cap.stdout.contains("rc=3"))
    }

    @Test func waitOnUnknownPidReturns127() async throws {
        let cap = makeShell()
        try await cap.shell.run("wait 999999; echo rc=$?")
        #expect(cap.stdout.contains("rc=127"))
        #expect(cap.stderr.contains("not a child of this shell"))
    }

    @Test func backgroundedSubshellRunsInIsolation() async throws {
        let cap = makeShell()
        // Variable mutations inside the backgrounded subshell shouldn't
        // leak out to the parent.
        try await cap.shell.run("""
            x=outer
            ( x=inner; sleep 0.05 ) &
            wait
            echo "x=$x"
            """)
        #expect(cap.stdout.contains("x=outer"))
    }

    // MARK: Cancellation throughout commands

    @Test func killCancelsLongRunningSleep() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            sleep 5 &
            sleep 0.05
            kill $!
            wait $!
            echo "rc=$?"
            """)
        // 128 + SIGTERM = 143; cooperative cancel via Task.sleep.
        #expect(cap.stdout.contains("rc=143"))
    }

    @Test func killCancelsLongRunningSeq() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            seq 1 1000000000 > /dev/null &
            sleep 0.05
            kill $!
            wait $!
            echo "rc=$?"
            """)
        // The cancellation point inside SeqCommand's generator loop
        // catches the cancel and unwinds within microseconds rather
        // than running all billion iterations.
        #expect(cap.stdout.contains("rc=143"))
    }

    @Test func killCancelsBusyShellLoop() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            (while true; do :; done) &
            sleep 0.05
            kill $!
            wait $!
            echo "rc=$?"
            """)
        #expect(cap.stdout.contains("rc=143"))
    }

    @Test func cancelDoesNotEmitStrayErrorMessage() async throws {
        // Regression: ParsableCommandBridge used to translate a
        // CancellationError thrown from a parsed command into
        // ArgumentParser's "Error: …" diagnostic and route it to
        // stderr. Make sure cancelled background jobs stay quiet.
        let cap = makeShell()
        try await cap.shell.run("""
            sleep 5 & sleep 0.05; kill $!; wait $!
            """)
        #expect(!cap.stderr.contains("Error: CancellationError"),
                "stderr leaked Swift Concurrency error: \(cap.stderr)")
    }
}
