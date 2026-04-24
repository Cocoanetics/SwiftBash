import XCTest
import Foundation
@testable import BashInterpreter

/// Exercises the two ways to consume a Shell's stdout:
///  1. `Shell.runCapturing` — convenience, drains the whole output.
///  2. Replacing `shell.stdout` with your own `OutputSink` and
///     iterating `bytes` / `lines` concurrently with the run.
final class StdoutStreamTests: XCTestCase {

    // MARK: runCapturing convenience

    func testRunCapturingReturnsStdout() async throws {
        let shell = Shell(stdout: .discard, stderr: .discard)
        let result = try await shell.runCapturing("echo hello; echo world")
        XCTAssertEqual(result.stdout, "hello\nworld\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitStatus, .success)
    }

    func testRunCapturingSplitsStderr() async throws {
        let shell = Shell(stdout: .discard, stderr: .discard)
        shell.register(name: "noisy") { _, shell in
            shell.stdout("out\n")
            shell.stderr("err\n")
            return .success
        }
        let result = try await shell.runCapturing("noisy")
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
    }

    func testRunCapturingRestoresShellStdioOnException() async throws {
        let shell = Shell(stdout: .discard, stderr: .discard)
        let originalStdout = shell.stdout
        _ = try? await shell.runCapturing("nosuchcommand")
        XCTAssertTrue(shell.stdout === originalStdout,
            "stdout should be restored even when run throws")
    }

    func testCapturingExitStatus() async throws {
        let shell = Shell(stdout: .discard, stderr: .discard)
        let result = try await shell.runCapturing("true; false")
        XCTAssertEqual(result.exitStatus, .failure)
    }

    // MARK: Live streaming — iterate stdout while the shell runs

    func testStreamingStdoutDeliversLinesLive() async throws {
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
        XCTAssertEqual(lines.map(\.0), ["first", "second", "third"])
        // First line appears immediately; later ones at least 70 ms apart.
        XCTAssertLessThan(lines[0].1, 0.05)
        XCTAssertGreaterThan(lines[1].1, 0.07)
        XCTAssertGreaterThan(lines[2].1, 0.14)
    }

    // MARK: Multiple consumers of the same sink? (shouldn't — stream is single-consumer)

    func testBytesAndOnWriteFireSynchronously() async throws {
        // `onWrite` is synchronous; the stream is also fed. Both paths
        // see every write, which is what lets the test CapturingShell
        // give synchronous access to the collected string while still
        // exposing the stream for live consumers.
        var seen: [Data] = []
        let sink = OutputSink { data in seen.append(data) }
        let shell = Shell(stdout: sink, stderr: .discard)

        try await shell.run("echo hi")
        sink.finish()

        // onWrite observed the data synchronously:
        let synchronouslySeen = seen.reduce(Data(), +)
        XCTAssertEqual(String(decoding: synchronouslySeen, as: UTF8.self),
                       "hi\n")

        // And the async stream has the same data:
        let drained = await sink.readAllString()
        XCTAssertEqual(drained, "hi\n")
    }

    // MARK: stdin stream feeds into stdout stream — end-to-end

    func testEndToEndBinaryPassThrough() async throws {
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
        XCTAssertEqual(received, payload)
    }
}
