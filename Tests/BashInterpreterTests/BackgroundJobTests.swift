import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// End-to-end tests for `&` background execution and `wait`.
@Suite struct BackgroundJobTests {

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
}
