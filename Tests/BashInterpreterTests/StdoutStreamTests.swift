import Testing
import Foundation
@testable import BashInterpreter

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = Data()
    var value: Data {
        lock.lock(); defer { lock.unlock() }; return _value
    }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        _value.append(data)
    }
}

/// Exercises the two ways to consume a Shell's stdout:
///  1. `Shell.runCapturing` — convenience, drains the whole output.
///  2. Replacing `shell.stdout` with your own `OutputSink` and
///     iterating `bytes` / `lines` concurrently with the run.
@Suite struct StdoutStreamTests {

    // MARK: runCapturing convenience

    @Test func runCapturingReturnsStdout() async throws {
        let shell = Shell(stdout: .discard, stderr: .discard)
        let result = try await shell.runCapturing("echo hello; echo world")
        #expect(result.stdout == "hello\nworld\n")
        #expect(result.stderr == "")
        #expect(result.exitStatus == .success)
    }

    @Test func runCapturingSplitsStderr() async throws {
        let shell = Shell(stdout: .discard, stderr: .discard)
        shell.register(name: "noisy") { _, shell in
            shell.stdout("out\n")
            shell.stderr("err\n")
            return .success
        }
        let result = try await shell.runCapturing("noisy")
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test func runCapturingRestoresShellStdioOnException() async throws {
        let shell = Shell(stdout: .discard, stderr: .discard)
        let originalStdout = shell.stdout
        _ = try? await shell.runCapturing("nosuchcommand")
        #expect(shell.stdout === originalStdout,
            "stdout should be restored even when run throws")
    }

    @Test func capturingExitStatus() async throws {
        let shell = Shell(stdout: .discard, stderr: .discard)
        let result = try await shell.runCapturing("true; false")
        #expect(result.exitStatus == .failure)
    }

    // MARK: Live streaming — iterate stdout while the shell runs

    @Test func streamingStdoutDeliversLinesLive() async throws {
        let shell = Shell(stderr: .discard)
        let sink = OutputSink()
        shell.stdout = sink

        // Consumer runs concurrently: it collects lines AND records
        // the wall-clock time of each arrival. For the cooperative
        // `sleep`-based producer, the deltas should match the inter-
        // line sleep — not be a single burst at the end.
        let start = Date()
        async let arrivals: [(String, TimeInterval)] = {
            var out: [(String, TimeInterval)] = []
            for await line in sink.lines {
                out.append((line, Date().timeIntervalSince(start)))
            }
            return out
        }()

        shell.register(name: "sleep") { argv, _ in
            let secs = Double(argv.dropFirst().first ?? "0") ?? 0
            try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            return .success
        }

        try await shell.run("""
            echo first
            sleep 0.08
            echo second
            sleep 0.08
            echo third
            """)
        sink.finish()

        let lines = await arrivals
        #expect(lines.map(\.0) == ["first", "second", "third"])
        // First line should be near-instant (well under one inter-line
        // sleep). Subsequent lines at least one sleep duration apart.
        // Generous bounds to absorb CI scheduler jitter.
        #expect(lines[0].1 < 0.07)
        #expect(lines[1].1 > 0.07)
        #expect(lines[2].1 > 0.14)
    }

    // MARK: Multiple consumers of the same sink? (shouldn't — stream is single-consumer)

    @Test func bytesAndOnWriteFireSynchronously() async throws {
        // `onWrite` is synchronous; the stream is also fed. Both paths
        // see every write, which is what lets the test CapturingShell
        // give synchronous access to the collected string while still
        // exposing the stream for live consumers.
        let seen = DataBox()
        let sink = OutputSink { data in seen.append(data) }
        let shell = Shell(stdout: sink, stderr: .discard)

        try await shell.run("echo hi")
        sink.finish()

        // onWrite observed the data synchronously:
        #expect(String(decoding: seen.value, as: UTF8.self) == "hi\n")

        // And the async stream has the same data:
        let drained = await sink.readAllString()
        #expect(drained == "hi\n")
    }

    // MARK: stdin stream feeds into stdout stream — end-to-end

    @Test func endToEndBinaryPassThrough() async throws {
        // Bytes pushed into stdin, pulled from stdout — full stream
        // round trip, binary-safe.
        let shell = Shell()
        let payload = Data([0x00, 0xFF, 0x7F, 0x80, 0x01])

        shell.stdin = .data(payload)
        let outSink = OutputSink()
        shell.stdout = outSink
        shell.stderr = .discard

        shell.register(name: "tee") { _, shell in
            for await chunk in shell.stdin.bytes {
                shell.stdout(chunk)
            }
            return .success
        }

        try await shell.run("tee")
        outSink.finish()
        let received = await outSink.readAllData()
        #expect(received == payload)
    }
}
