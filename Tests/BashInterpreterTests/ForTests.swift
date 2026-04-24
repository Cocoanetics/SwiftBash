import XCTest
@testable import BashInterpreter

final class ForTests: XCTestCase {

    func testForLiteralList() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("for x in a b c; do echo $x; done")
        XCTAssertEqual(cap.stdout, "a\nb\nc\n")
    }

    func testForEmptyListRunsNothing() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("for x in; do echo $x; done")
        XCTAssertEqual(cap.stdout, "")
    }

    func testForLeavesVariableAtLastValue() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("for x in a b c; do :; done")
        XCTAssertEqual(cap.shell.environment["x"], "c")
    }

    func testForWithVariableExpansion() async throws {
        let cap = CapturingShell()
        cap.shell.environment["item"] = "widget"
        try await cap.shell.run("for x in one $item; do echo $x; done")
        XCTAssertEqual(cap.stdout, "one\nwidget\n")
    }

    func testForExecutesBodyInOrder() async throws {
        let cap = CapturingShell()
        cap.shell.environment["total"] = "0"
        try await cap.shell.run("""
            for n in 1 2 3 4; do
              (( total = total + n ))
            done
            """)
        XCTAssertEqual(cap.shell.environment["total"], "10")
    }

    func testNestedFor() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            for a in x y; do
              for b in 1 2; do
                echo $a$b
              done
            done
            """)
        XCTAssertEqual(cap.stdout, "x1\nx2\ny1\ny2\n")
    }

    func testForCommandSubstitutionInList() async throws {
        let cap = CapturingShell()
        // $(echo a b c) produces the string "a b c" — without word splitting,
        // this currently iterates once (known limitation). Verify that.
        try await cap.shell.run("for x in $(echo a b c); do echo [$x]; done")
        XCTAssertEqual(cap.stdout, "[a b c]\n")
    }

    func testForWithoutInIsUnimplemented() async {
        let cap = CapturingShell()
        await XCTAssertThrowsErrorAsync(try await cap.shell.run("for x; do echo $x; done")) { err in
            XCTAssertTrue(err is BashInterpreterError, "got \(err)")
        }
    }
}
