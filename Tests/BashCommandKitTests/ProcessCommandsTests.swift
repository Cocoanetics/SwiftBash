import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Tests cover the **virtual** process model: `ps` / `kill` / `pgrep`
/// / `pkill` operate exclusively on ``Shell/processTable``, which is
/// populated by `&` background jobs. The host process table is never
/// touched.
@Suite(.timeLimit(.minutes(1))) struct ProcessCommandsTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: ps

    @Test func psWithNoBackgroundJobsShowsHeaderOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run("ps")
        // Header row only, no entries.
        let lines = cap.stdout.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].contains("PID"))
        #expect(lines[0].contains("COMMAND"))
    }

    @Test func psShowsBackgroundedJobs() async throws {
        let cap = makeShell()
        try await cap.shell.run(
            "sleep 0.5 & ps; wait")
        // Two lines: header + one entry.
        #expect(cap.stdout.contains("sleep 0.5"))
    }

    @Test func psFilterByPid() async throws {
        let cap = makeShell()
        try await cap.shell.run(
            "sleep 0.5 & PID=$!; ps -p $PID; wait")
        #expect(cap.stdout.contains("sleep 0.5"))
    }

    @Test func psCustomColumns() async throws {
        let cap = makeShell()
        try await cap.shell.run(
            "sleep 0.5 & ps -o pid,state; wait")
        #expect(cap.stdout.contains("PID"))
        #expect(cap.stdout.contains("STAT"))
    }

    // MARK: kill

    @Test func killInvalidPid() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("kill 999999")
        #expect(status == .failure)
        #expect(cap.stderr.contains("No such process"))
    }

    @Test func killCancelsBackgroundedLoop() async throws {
        let cap = makeShell()
        // Backgrounded busy loop hits the while-loop cancel point and
        // unwinds. `wait` returns 143 (128 + SIGTERM convention).
        try await cap.shell.run("""
            i=0
            while true; do i=$((i+1)); done &
            sleep 0.05
            kill $!
            wait $!
            echo "rc=$?"
            """)
        #expect(cap.stdout.contains("rc=143"))
    }

    @Test func killListsSignals() async throws {
        let cap = makeShell()
        try await cap.shell.run("kill -l")
        #expect(cap.stdout.contains("HUP"))
        #expect(cap.stdout.contains("TERM"))
    }

    // MARK: pgrep

    @Test func pgrepFindsBackgroundedJob() async throws {
        let cap = makeShell()
        try await cap.shell.run(
            "sleep 0.5 & pgrep sleep; wait")
        let pids = cap.stdout.split(separator: "\n").compactMap { Int32($0) }
        #expect(!pids.isEmpty)
    }

    @Test func pgrepNoMatch() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run(
            "pgrep zzzzzz_definitely_not_a_process")
        #expect(status == ExitStatus(1))
    }

    @Test func pkillCancelsMatching() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            i=0
            while true; do i=$((i+1)); done &
            sleep 0.05
            pkill 'while true'
            wait $!
            echo "rc=$?"
            """)
        #expect(cap.stdout.contains("rc=143"))
    }

    // MARK: $!

    @Test func dollarBangIsLastBackgroundPid() async throws {
        let cap = makeShell()
        try await cap.shell.run("sleep 0.05 & echo $!; wait")
        let trimmed = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Default starting PID is 1000.
        #expect(Int32(trimmed) != nil)
        #expect((Int32(trimmed) ?? 0) >= 1000)
    }
}
