import XCTest
@testable import BashInterpreter
@testable import BashCommandKit

final class SeqCommandTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(SeqCommand.self)
        return cap
    }

    func testOneArg() throws {
        let cap = makeShell()
        try cap.shell.run("seq 3")
        XCTAssertEqual(cap.stdout, "1\n2\n3\n")
    }

    func testTwoArgs() throws {
        let cap = makeShell()
        try cap.shell.run("seq 2 5")
        XCTAssertEqual(cap.stdout, "2\n3\n4\n5\n")
    }

    func testThreeArgsIncrement() throws {
        let cap = makeShell()
        try cap.shell.run("seq 1 2 9")
        XCTAssertEqual(cap.stdout, "1\n3\n5\n7\n9\n")
    }

    func testDescending() throws {
        let cap = makeShell()
        try cap.shell.run("seq 5 -1 1")
        XCTAssertEqual(cap.stdout, "5\n4\n3\n2\n1\n")
    }

    func testCustomSeparator() throws {
        let cap = makeShell()
        try cap.shell.run("seq -s , 4")
        XCTAssertEqual(cap.stdout, "1,2,3,4\n")
    }

    func testEmptySequenceIfRangeInverted() throws {
        let cap = makeShell()
        try cap.shell.run("seq 5 1")   // first > last with default step 1
        XCTAssertEqual(cap.stdout, "\n", "empty list plus trailing newline")
    }

    func testZeroIncrementFails() throws {
        let cap = makeShell()
        let status = try cap.shell.run("seq 1 0 10")
        XCTAssertFalse(status.isSuccess)
        XCTAssertTrue(cap.stderr.contains("zero"), cap.stderr)
    }

    func testFloatIncrement() throws {
        let cap = makeShell()
        try cap.shell.run("seq 1 0.5 2")
        XCTAssertEqual(cap.stdout, "1\n1.5\n2\n")
    }

    func testTooManyArgsFails() throws {
        let cap = makeShell()
        let status = try cap.shell.run("seq 1 2 3 4")
        XCTAssertFalse(status.isSuccess)
    }

    func testCommandSubstitution() throws {
        let cap = makeShell()
        try cap.shell.run("out=$(seq -s , 3); echo $out")
        XCTAssertEqual(cap.stdout, "1,2,3\n")
    }
}
