import XCTest
@testable import BashInterpreter

/// A test helper wiring a Shell up to in-memory buffers. Bytes written
/// by `shell.stdout(_:)` / `shell.stderr(_:)` are UTF-8 decoded and
/// appended to the `stdout` / `stderr` strings on this instance —
/// the common case for assertion. The underlying `OutputSink`s still
/// expose `.bytes` streams if a test needs to consume output live.
final class CapturingShell {
    let shell: Shell

    private final class StringBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ data: Data) {
            let s = String(decoding: data, as: UTF8.self)
            lock.lock(); defer { lock.unlock() }
            value.append(s)
        }
        func read() -> String {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    private let _stdout = StringBox()
    private let _stderr = StringBox()

    var stdout: String { _stdout.read() }
    var stderr: String { _stderr.read() }

    init(environment: Environment = Environment()) {
        let stdoutSink = OutputSink(onWrite: { [weak _stdout] data in
            _stdout?.append(data)
        })
        let stderrSink = OutputSink(onWrite: { [weak _stderr] data in
            _stderr?.append(data)
        })
        self.shell = Shell(environment: environment,
                           stdout: stdoutSink,
                           stderr: stderrSink)
    }
}

/// Evaluate `expression`; XCTest doesn't have a built-in async variant of
/// `XCTAssertThrowsError`, so we provide one. Fails the test if no
/// error is thrown.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "expected an error" : message(),
                file: file, line: line)
    } catch {
        handler(error)
    }
}

final class ShellTests: XCTestCase {

    // MARK: Basic smoke

    func testEchoHelloWorld() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("echo hello world")
        XCTAssertEqual(status, .success)
        XCTAssertEqual(cap.stdout, "hello world\n")
    }

    func testEmptyInputIsSuccess() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("")
        XCTAssertEqual(status, .success)
        XCTAssertEqual(cap.stdout, "")
    }

    func testCommandNotFoundThrows() async {
        let cap = CapturingShell()
        await XCTAssertThrowsErrorAsync(try await cap.shell.run("nosuchcommand")) { err in
            guard let e = err as? BashInterpreterError,
                  case .commandNotFound(let name) = e
            else { return XCTFail("expected commandNotFound, got \(err)") }
            XCTAssertEqual(name, "nosuchcommand")
        }
    }

    func testLastExitStatusTracksCommands() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("true")
        XCTAssertEqual(cap.shell.lastExitStatus, .success)
        try await cap.shell.run("false")
        XCTAssertEqual(cap.shell.lastExitStatus, .failure)
    }
}
