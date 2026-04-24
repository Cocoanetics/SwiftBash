import XCTest
@testable import BashInterpreter
@testable import BashCommandKit

final class DirnameCommandTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(DirnameCommand.self)
        return cap
    }

    func testSimplePath() throws {
        let cap = makeShell()
        try cap.shell.run("dirname /tmp/foo.txt")
        XCTAssertEqual(cap.stdout, "/tmp\n")
    }

    func testNoSlashReturnsDot() throws {
        let cap = makeShell()
        try cap.shell.run("dirname foo.txt")
        XCTAssertEqual(cap.stdout, ".\n")
    }

    func testRelativePath() throws {
        let cap = makeShell()
        try cap.shell.run("dirname foo/bar")
        XCTAssertEqual(cap.stdout, "foo\n")
    }

    func testTrailingSlashReturnsParent() throws {
        let cap = makeShell()
        try cap.shell.run("dirname /tmp/")
        XCTAssertEqual(cap.stdout, "/\n")
    }

    func testRootPath() throws {
        let cap = makeShell()
        try cap.shell.run("dirname /foo")
        XCTAssertEqual(cap.stdout, "/\n")
    }

    func testRootSlashItself() throws {
        let cap = makeShell()
        try cap.shell.run("dirname /")
        XCTAssertEqual(cap.stdout, "/\n")
    }

    func testDeepPath() throws {
        let cap = makeShell()
        try cap.shell.run("dirname /a/b/c/d/e")
        XCTAssertEqual(cap.stdout, "/a/b/c/d\n")
    }

    func testEmptyStringReturnsDot() throws {
        let cap = makeShell()
        try cap.shell.run(#"dirname """#)
        XCTAssertEqual(cap.stdout, ".\n")
    }
}
