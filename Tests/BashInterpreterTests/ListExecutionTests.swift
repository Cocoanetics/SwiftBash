import XCTest
@testable import BashInterpreter

final class ListExecutionTests: XCTestCase {

    func testSemicolonRunsBoth() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo a; echo b")
        XCTAssertEqual(cap.stdout, "a\nb\n")
    }

    func testAndAndShortCircuitsOnFailure() throws {
        let cap = CapturingShell()
        try cap.shell.run("false && echo nope")
        XCTAssertEqual(cap.stdout, "")
    }

    func testAndAndContinuesOnSuccess() throws {
        let cap = CapturingShell()
        try cap.shell.run("true && echo yes")
        XCTAssertEqual(cap.stdout, "yes\n")
    }

    func testOrOrShortCircuitsOnSuccess() throws {
        let cap = CapturingShell()
        try cap.shell.run("true || echo nope")
        XCTAssertEqual(cap.stdout, "")
    }

    func testOrOrFiresOnFailure() throws {
        let cap = CapturingShell()
        try cap.shell.run("false || echo fallback")
        XCTAssertEqual(cap.stdout, "fallback\n")
    }

    func testMultipleLinesRunInOrder() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo one\necho two\necho three")
        XCTAssertEqual(cap.stdout, "one\ntwo\nthree\n")
    }

    func testExitStatusPropagates() throws {
        let cap = CapturingShell()
        let status = try cap.shell.run("true; false")
        XCTAssertEqual(status, .failure)
    }
}
