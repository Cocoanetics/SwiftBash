import XCTest
@testable import BashInterpreter

final class ForTests: XCTestCase {

    func testForLiteralList() throws {
        let cap = CapturingShell()
        try cap.shell.run("for x in a b c; do echo $x; done")
        XCTAssertEqual(cap.stdout, "a\nb\nc\n")
    }

    func testForEmptyListRunsNothing() throws {
        let cap = CapturingShell()
        try cap.shell.run("for x in; do echo $x; done")
        XCTAssertEqual(cap.stdout, "")
    }

    func testForLeavesVariableAtLastValue() throws {
        let cap = CapturingShell()
        try cap.shell.run("for x in a b c; do :; done")
        XCTAssertEqual(cap.shell.environment["x"], "c")
    }

    func testForWithVariableExpansion() throws {
        let cap = CapturingShell()
        cap.shell.environment["item"] = "widget"
        try cap.shell.run("for x in one $item; do echo $x; done")
        XCTAssertEqual(cap.stdout, "one\nwidget\n")
    }

    func testForExecutesBodyInOrder() throws {
        let cap = CapturingShell()
        cap.shell.environment["total"] = "0"
        try cap.shell.run("""
            for n in 1 2 3 4; do
              (( total = total + n ))
            done
            """)
        XCTAssertEqual(cap.shell.environment["total"], "10")
    }

    func testNestedFor() throws {
        let cap = CapturingShell()
        try cap.shell.run("""
            for a in x y; do
              for b in 1 2; do
                echo $a$b
              done
            done
            """)
        XCTAssertEqual(cap.stdout, "x1\nx2\ny1\ny2\n")
    }

    func testForCommandSubstitutionInList() throws {
        let cap = CapturingShell()
        // $(echo a b c) produces the string "a b c" — without word splitting,
        // this currently iterates once (known limitation). Verify that.
        try cap.shell.run("for x in $(echo a b c); do echo [$x]; done")
        XCTAssertEqual(cap.stdout, "[a b c]\n")
    }

    func testForWithoutInIsUnimplemented() {
        let cap = CapturingShell()
        XCTAssertThrowsError(try cap.shell.run("for x; do echo $x; done")) { err in
            XCTAssertTrue(err is BashInterpreterError, "got \(err)")
        }
    }
}
