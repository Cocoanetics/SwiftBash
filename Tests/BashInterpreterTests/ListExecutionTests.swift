import XCTest
@testable import BashInterpreter

final class ListExecutionTests: XCTestCase {

    func testSemicolonRunsBoth() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo a; echo b")
        XCTAssertEqual(cap.stdout, "a\nb\n")
    }

    func testAndAndShortCircuitsOnFailure() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("false && echo nope")
        XCTAssertEqual(cap.stdout, "")
    }

    func testAndAndContinuesOnSuccess() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("true && echo yes")
        XCTAssertEqual(cap.stdout, "yes\n")
    }

    func testOrOrShortCircuitsOnSuccess() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("true || echo nope")
        XCTAssertEqual(cap.stdout, "")
    }

    func testOrOrFiresOnFailure() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("false || echo fallback")
        XCTAssertEqual(cap.stdout, "fallback\n")
    }

    func testMultipleLinesRunInOrder() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo one\necho two\necho three")
        XCTAssertEqual(cap.stdout, "one\ntwo\nthree\n")
    }

    func testExitStatusPropagates() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("true; false")
        XCTAssertEqual(status, .failure)
    }
}
