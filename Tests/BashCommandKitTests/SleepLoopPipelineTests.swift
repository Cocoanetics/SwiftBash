import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Demonstrates the "long-running producer feeds a streaming consumer"
/// pattern you'd want for live-tailing something in an app. Uses
/// sub-second sleeps so the tests stay fast.
@Suite struct SleepLoopPipelineTests {

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

    /// The consumer observes each produced line as it's produced —
    /// verifying that `sleep` between yields doesn't hold up the
    /// downstream stage.
    @Test func consumerReceivesLinesAsProduced() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()

        // Record the wall-clock time at which each line reaches the
        // consumer.
        let arrivals: LineArrivalRecorder = LineArrivalRecorder()
        cap.shell.register(name: "record") { _, shell in
            for await line in shell.stdin.lines {
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
        #expect(times[1] - times[0] > 0.05,
            "lines shouldn't all burst out at once")
    }
}

// MARK: helpers

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
