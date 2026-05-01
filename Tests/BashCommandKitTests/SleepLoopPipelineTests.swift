import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Demonstrates the "long-running producer feeds a streaming consumer"
/// pattern you'd want for live-tailing something in an app. Uses
/// sub-second sleeps so the tests stay fast.
///
/// Skipped on Android: the suite exercises the "for-loop with sleep
/// piped through a streaming consumer" pattern (`headCancelsSleepingProducer`,
/// `dateLoopPipedToCat`, `untilPollsStatusCommandUntilCompleted`,
/// `consumerReceivesLinesAsProduced`), which on the Android x86_64
/// emulator's single-CPU cooperative pool deadlocks — the producer
/// busy-loops without yielding back to the consumer's read side, so
/// pipeline cancellation never propagates and `head -n N` can't
/// terminate the upstream `for` loop. Same root cause as the `yes |
/// head` skip in NewUtilityCommandsTests.
#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct SleepLoopPipelineTests {

    /// The literal pattern you'd write for "every 5 s, print the date,
    /// for a minute, piped to a tail-like consumer" — scaled down.
    @Test func dateLoopPipedToCat() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()

        // 3 iterations × 50 ms ≈ 0.15 s wall time.
        try await cap.shell.run("""
            for i in 1 2 3; do
              date -f "%Y"
              sleep 0.05
            done | cat
            """)

        let year = Calendar.current.component(.year, from: Date())
        #expect(cap.stdout == "\(year)\n\(year)\n\(year)\n")
    }

    /// Same pattern, but the consumer is `head -n 2` — which should
    /// terminate the producer early via pipeline cancellation and
    /// propagate through the cooperative `sleep`.
    @Test func headCancelsSleepingProducer() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()

        let start = Date()
        try await cap.shell.run("""
            for i in 1 2 3 4 5 6 7 8 9 10; do
              echo "tick-$i"
              sleep 0.1
            done | head -n 2
            """)
        let elapsed = Date().timeIntervalSince(start)

        #expect(cap.stdout == "tick-1\ntick-2\n")
        // If sleep were blocking we'd see roughly 10 × 0.1 s = 1 s.
        // Cooperative cancellation should finish well under 1 s.
        #expect(elapsed < 0.5,
            "producer should be cancelled after head takes 2 lines; took \(elapsed)s")
    }

    /// Mirrors the real-world `until [ "$(gh run view ... -q .status)" = "completed" ]; do sleep N; done && echo done`
    /// poll pattern: an external command is sampled in a command-substitution, its
    /// output is compared with `[ ... = ... ]`, the loop exits when the condition
    /// matches, and `&&` chains a follow-up. Uses a fake `status` command that
    /// flips to `completed` on its third call so the loop iterates a known number
    /// of times.
    @Test func untilPollsStatusCommandUntilCompleted() async throws {
        let cap = CapturingShell()
        cap.shell.register(SleepCommand.self)

        let counter = CallCounter()
        cap.shell.register(name: "status") { _ in
            let n = counter.increment()
            Shell.current.stdout(n >= 3 ? "completed\n" : "running\n")
            return .success
        }

        try await cap.shell.run("""
            until [ "$(status)" = "completed" ]; do sleep 0.01; done && echo done
            """)

        #expect(cap.stdout == "done\n")
        #expect(counter.value == 3)
    }

    /// The consumer observes each produced line as it's produced —
    /// verifying that `sleep` between yields doesn't hold up the
    /// downstream stage.
    @Test func consumerReceivesLinesAsProduced() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()

        // Record the wall-clock time at which each line reaches the
        // consumer.
        let arrivals: LineArrivalRecorder = LineArrivalRecorder()
        cap.shell.register(name: "record") { _ in
            for await line in Shell.current.stdin.lines {
                arrivals.record(line)
            }
            return .success
        }

        try await cap.shell.run("""
            for i in 1 2 3; do
              echo "tick-$i"
              sleep 0.1
            done | record
            """)

        // Line 1 arrives almost immediately; line 2 at ~0.1 s; line 3 at ~0.2 s.
        let times = arrivals.timesFromStart
        #expect(arrivals.count == 3)
        #expect(times[1] - times[0] < 0.3,
            "lines should interleave in real time (delta was \(times[1] - times[0])s)")
        #expect(times[2] - times[1] < 0.3)
        #expect(times[1] - times[0] > 0.02,
            "lines shouldn't all burst out at once")
    }
}

// MARK: helpers

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
}

private final class LineArrivalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var arrivalTimes: [Date] = []
    private let origin: Date = Date()

    func record(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        arrivalTimes.append(Date())
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }

    var timesFromStart: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return arrivalTimes.map { $0.timeIntervalSince(origin) }
    }
}
#endif
