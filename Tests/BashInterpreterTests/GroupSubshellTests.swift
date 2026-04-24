import XCTest
@testable import BashInterpreter

final class GroupSubshellTests: XCTestCase {

    func testGroupRunsAllCommands() throws {
        let cap = CapturingShell()
        try cap.shell.run("{ echo a; echo b; echo c; }")
        XCTAssertEqual(cap.stdout, "a\nb\nc\n")
    }

    func testGroupExitStatusIsLast() throws {
        let cap = CapturingShell()
        let status = try cap.shell.run("{ true; false; }")
        XCTAssertEqual(status, .failure)
    }

    func testSubshellRunsCommands() throws {
        let cap = CapturingShell()
        try cap.shell.run("(echo a; echo b)")
        XCTAssertEqual(cap.stdout, "a\nb\n")
    }

    /// In real bash, a subshell gets an environment copy — changes inside
    /// don't leak back. Without subprocess isolation this skeleton leaks.
    /// Test documents the current (incorrect) behaviour so it's obvious
    /// when we fix it later.
    func testSubshellAssignmentCurrentlyLeaks() throws {
        let cap = CapturingShell()
        try cap.shell.run("(X=inside); echo after=$X")
        XCTAssertEqual(cap.stdout, "after=inside\n",
            "Subshell isolation not yet implemented — this will change "
            + "once subprocess support lands.")
    }

    func testGroupAssignmentVisible() throws {
        // Groups DO share the shell's env (matching bash).
        let cap = CapturingShell()
        try cap.shell.run("{ X=inside; }; echo $X")
        XCTAssertEqual(cap.stdout, "inside\n")
    }
}
