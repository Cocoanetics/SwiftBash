import XCTest
@testable import BashInterpreter

final class IfTests: XCTestCase {

    func testIfTrueRunsBody() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("if true; then echo yes; fi")
        XCTAssertEqual(cap.stdout, "yes\n")
    }

    func testIfFalseSkipsBody() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("if false; then echo nope; fi")
        XCTAssertEqual(cap.stdout, "")
    }

    func testIfElse() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("if false; then echo yes; else echo no; fi")
        XCTAssertEqual(cap.stdout, "no\n")
    }

    func testElifFirstBranchHits() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            if true; then echo one
            elif true; then echo two
            else echo three
            fi
            """)
        XCTAssertEqual(cap.stdout, "one\n")
    }

    func testElifSecondBranchHits() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            if false; then echo one
            elif true; then echo two
            else echo three
            fi
            """)
        XCTAssertEqual(cap.stdout, "two\n")
    }

    func testElseFallsThrough() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            if false; then echo one
            elif false; then echo two
            else echo three
            fi
            """)
        XCTAssertEqual(cap.stdout, "three\n")
    }

    func testIfWithArithmeticCondition() async throws {
        let cap = CapturingShell()
        cap.shell.environment["x"] = "10"
        try await cap.shell.run("if (( x > 5 )); then echo big; else echo small; fi")
        XCTAssertEqual(cap.stdout, "big\n")
    }

    func testIfExitStatusIsLastRunCommand() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("if true; then false; fi")
        XCTAssertEqual(status, .failure)
    }

    func testIfNoMatchReturnsSuccess() async throws {
        // No else clause and condition is false → exit 0 per bash.
        let cap = CapturingShell()
        let status = try await cap.shell.run("if false; then echo nope; fi")
        XCTAssertEqual(status, .success)
    }

    func testIfInsideIf() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            if true; then
              if false; then echo inner-yes
              else echo inner-no
              fi
            fi
            """)
        XCTAssertEqual(cap.stdout, "inner-no\n")
    }
}
