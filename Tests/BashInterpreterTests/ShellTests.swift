import XCTest
@testable import BashInterpreter

/// A test helper wiring a Shell up to in-memory buffers. Bytes written
/// by `shell.stdout(_:)` / `shell.stderr(_:)` are UTF-8 decoded and
/// appended to the `stdout` / `stderr` strings on this instance —
/// the common case for assertion.
final class CapturingShell {
    let shell: Shell
    var stdout = ""
    var stderr = ""

    init(environment: Environment = Environment()) {
        self.shell = Shell(environment: environment)
        self.shell.stdout = { [weak self] data in
            self?.stdout.append(String(decoding: data, as: UTF8.self))
        }
        self.shell.stderr = { [weak self] data in
            self?.stderr.append(String(decoding: data, as: UTF8.self))
        }
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
