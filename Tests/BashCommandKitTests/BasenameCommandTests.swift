import XCTest
@testable import BashInterpreter
@testable import BashCommandKit

final class BasenameCommandTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(BasenameCommand.self)
        return cap
    }

    func testBasicFileName() throws {
        let cap = makeShell()
        try cap.shell.run("basename /tmp/foo.txt")
        XCTAssertEqual(cap.stdout, "foo.txt\n")
    }

    func testNoSlashesReturnsInput() throws {
        let cap = makeShell()
        try cap.shell.run("basename foo.txt")
        XCTAssertEqual(cap.stdout, "foo.txt\n")
    }

    func testTrailingSlash() throws {
        let cap = makeShell()
        try cap.shell.run("basename /tmp/")
        XCTAssertEqual(cap.stdout, "tmp\n")
    }

    func testRootSlash() throws {
        let cap = makeShell()
        try cap.shell.run("basename /")
        XCTAssertEqual(cap.stdout, "/\n")
    }

    func testStripsSuffix() throws {
        let cap = makeShell()
        try cap.shell.run("basename /tmp/foo.txt .txt")
        XCTAssertEqual(cap.stdout, "foo\n")
    }

    func testSuffixMismatchLeavesNameIntact() throws {
        let cap = makeShell()
        try cap.shell.run("basename /tmp/foo.txt .md")
        XCTAssertEqual(cap.stdout, "foo.txt\n")
    }

    func testSuffixEqualToResultIsNotStripped() throws {
        let cap = makeShell()
        try cap.shell.run("basename .txt .txt")
        XCTAssertEqual(cap.stdout, ".txt\n")
    }

    func testDeepPath() throws {
        let cap = makeShell()
        try cap.shell.run("basename /a/b/c/d/e")
        XCTAssertEqual(cap.stdout, "e\n")
    }

    func testMissingPathFails() throws {
        let cap = makeShell()
        let status = try cap.shell.run("basename")
        XCTAssertFalse(status.isSuccess)
        XCTAssertFalse(cap.stderr.isEmpty)
    }
}
