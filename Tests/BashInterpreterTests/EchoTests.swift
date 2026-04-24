import XCTest
@testable import BashInterpreter

final class EchoTests: XCTestCase {

    func testNoArgs() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo")
        XCTAssertEqual(cap.stdout, "\n")
    }

    func testSingleArg() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo hi")
        XCTAssertEqual(cap.stdout, "hi\n")
    }

    func testMultipleArgsJoinedWithSpace() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo a b c")
        XCTAssertEqual(cap.stdout, "a b c\n")
    }

    func testDashNSuppressesNewline() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo -n hello")
        XCTAssertEqual(cap.stdout, "hello")
    }

    func testDoubleDashEndsOptions() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo -- -n literal")
        XCTAssertEqual(cap.stdout, "-n literal\n")
    }

    func testQuotesAreStripped() throws {
        let cap = CapturingShell()
        try cap.shell.run(#"echo "hello world""#)
        XCTAssertEqual(cap.stdout, "hello world\n")
    }

    func testSingleQuotesPreserveDollars() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "expanded"
        try cap.shell.run("echo '$X'")
        XCTAssertEqual(cap.stdout, "$X\n")
    }
}
