import Testing
import Foundation
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct ProcessTableTests {

    // MARK: spawn / wait

    @Test func spawnReturnsMonotonicVirtualPids() async {
        let table = ProcessTable(startingAt: 100)
        let p1 = await table.spawn(command: "a") { .success }
        let p2 = await table.spawn(command: "b") { .success }
        let p3 = await table.spawn(command: "c") { .success }
        #expect(p1 == 100)
        #expect(p2 == 101)
        #expect(p3 == 102)
    }

    @Test func waitReturnsExitStatus() async {
        let table = ProcessTable()
        let pid = await table.spawn(command: "ok") {
            try? await Task.sleep(nanoseconds: 10_000_000)
            return ExitStatus(42)
        }
        let status = await table.wait(pid: pid)
        #expect(status?.code == 42)
    }

    @Test func waitOnUnknownPidIsNil() async {
        let table = ProcessTable()
        let status = await table.wait(pid: 999_999)
        #expect(status == nil)
    }

    @Test func waitAllAwaitsEverything() async {
        let table = ProcessTable()
        let started = Date()
        for _ in 0..<3 {
            _ = await table.spawn(command: "x") {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return .success
            }
        }
        _ = await table.waitAll()
        let elapsed = Date().timeIntervalSince(started)
        // Three 100ms tasks serially would need ≥300ms (i.e. ~0.300).
        // We assert significantly under that to prove concurrency.
        // The bound is loose because the macOS xctest scheduler isn't
        // a soft real-time system — busy CI runs sometimes drift to
        // ~0.295. The serial floor of 0.300 is the meaningful signal.
        #expect(elapsed < 0.295,
                "expected parallel completion, got \(elapsed)s")
    }

    @Test func waitAllReturnsLastStatus() async {
        let table = ProcessTable()
        _ = await table.spawn(command: "a") { .success }
        _ = await table.spawn(command: "b") { ExitStatus(7) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let last = await table.waitAll()
        // Either status is acceptable depending on completion order;
        // primary assertion is that it didn't deadlock.
        #expect(last.code == 0 || last.code == 7)
    }

    // MARK: signal / cancellation

    @Test func signalCancelsRunningTask() async {
        let table = ProcessTable()
        let pid = await table.spawn(command: "loop") {
            // Cooperative loop honoring cancellation.
            while true {
                try Task.checkCancellation()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let ok = await table.signal(pid: pid)
        #expect(ok)
        let status = await table.wait(pid: pid)
        // 128 + SIGTERM = 143; cancellation maps there.
        #expect(status?.code == 143)
    }

    @Test func signalUnknownPidReturnsFalse() async {
        let table = ProcessTable()
        let ok = await table.signal(pid: 999_999)
        #expect(!ok)
    }

    // MARK: list / introspection

    @Test func listShowsAllSpawnedEntries() async {
        let table = ProcessTable(startingAt: 1)
        _ = await table.spawn(command: "alpha") { .success }
        _ = await table.spawn(command: "beta") { .success }
        let entries = await table.list()
        #expect(entries.count == 2)
        #expect(entries[0].command == "alpha")
        #expect(entries[1].command == "beta")
    }

    @Test func entriesMoveToExitedAfterCompletion() async {
        let table = ProcessTable()
        let pid = await table.spawn(command: "fast") {
            ExitStatus(11)
        }
        _ = await table.wait(pid: pid)
        // Give the completion observer one tick to record the state.
        try? await Task.sleep(nanoseconds: 10_000_000)
        let entry = await table.entry(for: pid)
        if case .exited(let s) = entry?.state {
            #expect(s.code == 11)
        } else {
            Issue.record("expected .exited, got \(String(describing: entry?.state))")
        }
    }

    @Test func lastBackgroundPidTracksMostRecent() async {
        let table = ProcessTable(startingAt: 50)
        _ = await table.spawn(command: "a") { .success }
        _ = await table.spawn(command: "b") { .success }
        let last = await table.lastBackgroundPID
        #expect(last == 51)
    }
}
#endif
