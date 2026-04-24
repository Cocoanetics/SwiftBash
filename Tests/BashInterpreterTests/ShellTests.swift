import XCTest
@testable import BashInterpreter

/// A test helper that wires a Shell up to a string buffer for stdout/stderr.
final class CapturingShell {
    let shell: Shell
    var stdout = ""
    var stderr = ""

    init(environment: Environment = Environment()) {
        self.shell = Shell(environment: environment)
        self.shell.stdout = { [weak self] s in self?.stdout.append(s) }
        self.shell.stderr = { [weak self] s in self?.stderr.append(s) }
    }
}

final class ShellTests: XCTestCase {

    // MARK: Basic smoke

    func testEchoHelloWorld() throws {
        let cap = CapturingShell()
        let status = try cap.shell.run("echo hello world")
        XCTAssertEqual(status, .success)
        XCTAssertEqual(cap.stdout, "hello world\n")
    }

    func testEmptyInputIsSuccess() throws {
        let cap = CapturingShell()
        let status = try cap.shell.run("")
        XCTAssertEqual(status, .success)
        XCTAssertEqual(cap.stdout, "")
    }

    func testCommandNotFoundThrows() {
        let cap = CapturingShell()
        XCTAssertThrowsError(try cap.shell.run("nosuchcommand")) { err in
            guard let e = err as? BashInterpreterError,
                  case .commandNotFound(let name) = e
            else { return XCTFail("expected commandNotFound, got \(err)") }
            XCTAssertEqual(name, "nosuchcommand")
        }
    }

    func testLastExitStatusTracksCommands() throws {
        let cap = CapturingShell()
        try cap.shell.run("true")
        XCTAssertEqual(cap.shell.lastExitStatus, .success)
        try cap.shell.run("false")
        XCTAssertEqual(cap.shell.lastExitStatus, .failure)
    }
}
