import XCTest
@testable import BashInterpreter

final class LoopControlTests: XCTestCase {

    // MARK: break

    func testBreakExitsWhile() async throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        try await cap.shell.run("""
            while (( i < 10 )); do
              if (( i == 3 )); then break; fi
              echo $i
              (( i++ ))
            done
            """)
        XCTAssertEqual(cap.stdout, "0\n1\n2\n")
        XCTAssertEqual(cap.shell.environment["i"], "3")
    }

    func testBreakExitsForArithCondition() async throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "0"
        try await cap.shell.run("""
            for x in 1 2 3 4 5; do
              (( x == 3 )) && break
              echo $x
            done
            """)
        XCTAssertEqual(cap.stdout, "1\n2\n")
    }

    func testBreakTwoLevels() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            for a in 1 2 3; do
              for b in 1 2 3; do
                echo $a.$b
                (( a == 1 && b == 2 )) && break 2
              done
            done
            """)
        XCTAssertEqual(cap.stdout, "1.1\n1.2\n")
    }

    // MARK: continue

    func testContinueSkipsIteration() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            for x in 1 2 3 4 5; do
              (( x == 3 )) && continue
              echo $x
            done
            """)
        XCTAssertEqual(cap.stdout, "1\n2\n4\n5\n")
    }

    func testContinueInWhile() async throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        try await cap.shell.run("""
            while (( i < 5 )); do
              (( i++ ))
              (( i == 3 )) && continue
              echo $i
            done
            """)
        XCTAssertEqual(cap.stdout, "1\n2\n4\n5\n")
    }

    func testContinueTwoLevels() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            for a in 1 2 3; do
              for b in 1 2 3; do
                (( a == 2 && b == 1 )) && continue 2
                echo $a.$b
              done
            done
            """)
        // Inner loop runs 1.1 1.2 1.3 for a=1, then for a=2 it immediately
        // continues the outer, skipping 2.*, then 3.1 3.2 3.3.
        XCTAssertEqual(cap.stdout, "1.1\n1.2\n1.3\n3.1\n3.2\n3.3\n")
    }

    // MARK: Edge cases

    func testBreakZeroIsAnError() async {
        let cap = CapturingShell()
        await XCTAssertThrowsErrorAsync(try await cap.shell.run("""
            for x in a; do break 0; done
            """))
    }

    func testStrayBreakWarnsAndContinues() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("break; echo after")
        XCTAssertEqual(status, .success)
        XCTAssertEqual(cap.stdout, "after\n")
        XCTAssertTrue(cap.stderr.contains("only meaningful"), cap.stderr)
    }

    func testStrayContinueWarns() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("continue")
        XCTAssertTrue(cap.stderr.contains("only meaningful"), cap.stderr)
    }

    // MARK: Exit status

    func testBreakReturnsSuccess() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("for x in 1; do break; done")
        XCTAssertEqual(status, .success)
    }
}
