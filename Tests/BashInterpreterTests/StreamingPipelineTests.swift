import Testing
import Foundation
@testable import BashInterpreter

/// The point of the async rewrite: pipelines where stages overlap in time,
/// and where a downstream consumer's termination unblocks the upstream
/// producer — the `yes | head` pattern — without OS-level `pipe(2)`.
///
/// Skipped on Android: the suite exercises the same pipe-cancellation
/// handshake that hangs SleepLoopPipelineTests / NewUtility's `yes |
/// head` tests on the single-CPU emulator. The downstream stage exits,
/// but the upstream producer's `stdout` write into the pipe channel
/// doesn't see the cancellation in time and the in-suite 2-second
/// task-group timeout itself blocks on the producer's never-finishing
/// task. Tracked alongside the SleepLoopPipelineTests skip.
#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct StreamingPipelineTests {

    private struct PipelineTimeout: Error {}

    // MARK: Producers used by these tests

    /// A producer that emits chunks forever until its write channel is
    /// closed (mimicking `yes` or an endless `tail -f`). Uses
    /// `Task.checkCancellation()` so it stops when the group cancels.
    private func registerInfiniteProducer(on shell: Shell,
                                          name: String,
                                          chunk: String) {
        shell.register(name: name) { _ in
            while !Task.isCancelled {
                Shell.current.stdout(chunk)
                // Yield so the consumer gets a chance to run and
                // potentially signal cancellation by closing its stdin.
                await Task.yield()
            }
            return .success
        }
    }

    // MARK: yes | head finishes

    @Test func finiteHeadTerminatesInfiniteUpstream() async throws {
        let cap = CapturingShell()
        registerInfiniteProducer(on: cap.shell, name: "yes", chunk: "y\n")

        // A simple stream-aware `head -n 3` implementation.
        cap.shell.register(name: "take3") { _ in
            var emitted = 0
            for await line in Shell.current.stdin.lines {
                Shell.current.stdout(line + "\n")
                emitted += 1
                if emitted >= 3 { break }
            }
            return .success
        }

        // Bound the overall operation so a regression can't hang the test.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await cap.shell.run("yes | take3")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
                throw PipelineTimeout()
            }
            try await group.next()
            group.cancelAll()
        }

        #expect(cap.stdout == "y\ny\ny\n")
    }

    // MARK: Stages overlap in time

    @Test func stagesRunConcurrently() async throws {
        // Producer records when it started yielding; consumer records
        // when it started consuming. For a sequential pipeline, the
        // consumer can't start until the producer finishes — so the
        // delta would be ≥ the producer's run time. For a concurrent
        // pipeline, the delta should be near-zero.
        let cap = CapturingShell()
        let producerStart = AtomicDate()
        let consumerStart = AtomicDate()

        cap.shell.register(name: "prod") { _ in
            producerStart.setNow()
            // Emit 10 lines with a small delay between each.
            for n in 1...10 {
                Shell.current.stdout("\(n)\n")
                try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
            }
            return .success
        }

        cap.shell.register(name: "cons") { _ in
            for await _ in Shell.current.stdin.lines {
                if consumerStart.value == nil {
                    consumerStart.setNow()
                }
            }
            return .success
        }

        try await cap.shell.run("prod | cons")

        guard let pStart = producerStart.value,
              let cStart = consumerStart.value
        else {
            Issue.record("timing not recorded")
            return
        }

        let delta = cStart.timeIntervalSince(pStart)
        #expect(delta < 0.1,
            "consumer should start while the producer is still running (delta was \(delta)s)")
    }

    // MARK: Binary safety

    @Test func binaryBytesPassThroughUnchanged() async throws {
        let cap = CapturingShell()

        // Raw bytes including high-bit and NUL — would be mangled by a
        // naive String-based pipe.
        let payload = Data([0x00, 0xFF, 0x7F, 0x80, 0x00, 0x01, 0xFE])

        cap.shell.register(name: "emit") { _ in
            Shell.current.stdout(payload)
            return .success
        }
        let received = AtomicData()
        cap.shell.register(name: "collect") { _ in
            received.value = await Shell.current.stdin.readAllData()
            return .success
        }

        try await cap.shell.run("emit | collect")
        #expect(received.value == payload)
    }

    // MARK: Subshell isolation

    @Test func pipelineStageMutationsDoNotLeak() async throws {
        // Variables assigned inside a pipeline stage should NOT
        // propagate back to the outer shell (matching bash).
        let cap = CapturingShell()
        cap.shell.environment["X"] = "outer"
        cap.shell.register(name: "stage") { _ in
            Shell.current.environment["X"] = "inside"
            let _ = await Shell.current.stdin.readAllData()
            return .success
        }
        try await cap.shell.run("true | stage")
        #expect(cap.shell.environment["X"] == "outer",
                "pipeline stage env mutations must stay subshell-local")
    }

    // MARK: Back-pressure

    @Test func consumerCanThrottleProducer() async throws {
        // With yielding producer + slow consumer, only a bounded amount
        // of data lives at once. This doesn't prove strict back-pressure
        // (AsyncStream default buffering policy is unbounded) but shows
        // that the pipeline still finishes correctly.
        let cap = CapturingShell()
        cap.shell.register(name: "burst") { _ in
            for i in 1...100 { Shell.current.stdout("\(i)\n") }
            return .success
        }
        cap.shell.register(name: "sum") { _ in
            var total = 0
            for await line in Shell.current.stdin.lines {
                total += Int(line) ?? 0
            }
            Shell.current.stdout("\(total)\n")
            return .success
        }
        try await cap.shell.run("burst | sum")
        #expect(cap.stdout == "5050\n")
    }
}

// MARK: Test helpers

/// Not-so-atomic date holder for timing checks. Thread-safe *enough*
/// for a single writer / single reader in the pipelines above.
private final class AtomicDate: @unchecked Sendable {
    private var _value: Date?
    private let lock = NSLock()
    var value: Date? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func setNow() {
        lock.lock(); defer { lock.unlock() }
        _value = Date()
    }
}

private final class AtomicData: @unchecked Sendable {
    private var _value: Data = Data()
    private let lock = NSLock()
    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
#endif
