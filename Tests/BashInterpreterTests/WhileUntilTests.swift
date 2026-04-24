import XCTest
@testable import BashInterpreter

final class WhileUntilTests: XCTestCase {

    // MARK: while

    func testWhileFalseNeverRuns() throws {
        let cap = CapturingShell()
        try cap.shell.run("while false; do echo nope; done")
        XCTAssertEqual(cap.stdout, "")
    }

    func testWhileArithmeticCounter() throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        try cap.shell.run("while (( i < 3 )); do echo $i; (( i++ )); done")
        XCTAssertEqual(cap.stdout, "0\n1\n2\n")
        XCTAssertEqual(cap.shell.environment["i"], "3")
    }

    func testWhileExitStatusIsLastBody() throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        let status = try cap.shell.run(
            "while (( i < 1 )); do (( i++ )); false; done"
        )
        XCTAssertEqual(status, .failure)
    }

    // MARK: until

    func testUntilRunsUntilConditionSucceeds() throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        try cap.shell.run("until (( i >= 3 )); do echo $i; (( i++ )); done")
        XCTAssertEqual(cap.stdout, "0\n1\n2\n")
    }

    func testUntilTrueNeverRuns() throws {
        let cap = CapturingShell()
        try cap.shell.run("until true; do echo nope; done")
        XCTAssertEqual(cap.stdout, "")
    }

    // MARK: Variable accumulation

    func testLoopAccumulatesInEnv() throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "0"
        cap.shell.environment["sum"] = "0"
        try cap.shell.run("""
            while (( n < 4 )); do
              (( sum = sum + n ))
              (( n++ ))
            done
            """)
        XCTAssertEqual(cap.shell.environment["sum"], "6") // 0+1+2+3
    }
}
