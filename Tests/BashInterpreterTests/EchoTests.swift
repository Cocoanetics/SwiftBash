import XCTest
@testable import BashInterpreter

final class EchoTests: XCTestCase {

    func testNoArgs() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo")
        XCTAssertEqual(cap.stdout, "\n")
    }

    func testSingleArg() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo hi")
        XCTAssertEqual(cap.stdout, "hi\n")
    }

    func testMultipleArgsJoinedWithSpace() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo a b c")
        XCTAssertEqual(cap.stdout, "a b c\n")
    }

    func testDashNSuppressesNewline() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo -n hello")
        XCTAssertEqual(cap.stdout, "hello")
    }

    func testDoubleDashEndsOptions() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo -- -n literal")
        XCTAssertEqual(cap.stdout, "-n literal\n")
    }

    func testQuotesAreStripped() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "hello world""#)
        XCTAssertEqual(cap.stdout, "hello world\n")
    }

    func testSingleQuotesPreserveDollars() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "expanded"
        try await cap.shell.run("echo '$X'")
        XCTAssertEqual(cap.stdout, "$X\n")
    }
}
