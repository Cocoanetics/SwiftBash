import XCTest
@testable import BashInterpreter
@testable import BashCommandKit

final class SeqCommandTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(SeqCommand.self)
        return cap
    }

    func testOneArg() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 3")
        XCTAssertEqual(cap.stdout, "1\n2\n3\n")
    }

    func testTwoArgs() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 2 5")
        XCTAssertEqual(cap.stdout, "2\n3\n4\n5\n")
    }

    func testThreeArgsIncrement() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 1 2 9")
        XCTAssertEqual(cap.stdout, "1\n3\n5\n7\n9\n")
    }

    func testDescending() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 5 -1 1")
        XCTAssertEqual(cap.stdout, "5\n4\n3\n2\n1\n")
    }

    func testCustomSeparator() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq -s , 4")
        XCTAssertEqual(cap.stdout, "1,2,3,4\n")
    }

    func testEmptySequenceIfRangeInverted() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 5 1")   // first > last with default step 1
        XCTAssertEqual(cap.stdout, "\n", "empty list plus trailing newline")
    }

    func testZeroIncrementFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("seq 1 0 10")
        XCTAssertFalse(status.isSuccess)
        XCTAssertTrue(cap.stderr.contains("zero"), cap.stderr)
    }

    func testFloatIncrement() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 1 0.5 2")
        XCTAssertEqual(cap.stdout, "1\n1.5\n2\n")
    }

    func testTooManyArgsFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("seq 1 2 3 4")
        XCTAssertFalse(status.isSuccess)
    }

    func testCommandSubstitution() async throws {
        let cap = makeShell()
        try await cap.shell.run("out=$(seq -s , 3); echo $out")
        XCTAssertEqual(cap.stdout, "1,2,3\n")
    }
}
