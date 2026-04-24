import XCTest
@testable import BashInterpreter

final class BuiltinsTests: XCTestCase {

    // MARK: true / false / :

    func testTrueAndFalse() throws {
        let cap = CapturingShell()
        XCTAssertEqual(try cap.shell.run("true"), .success)
        XCTAssertEqual(try cap.shell.run("false"), .failure)
    }

    func testColonIsSuccess() throws {
        let cap = CapturingShell()
        XCTAssertEqual(try cap.shell.run(": whatever"), .success)
        XCTAssertEqual(cap.stdout, "")
    }

    // MARK: pwd

    func testPwdPrintsWorkingDirectory() throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/tmp"
        try cap.shell.run("pwd")
        XCTAssertEqual(cap.stdout, "/tmp\n")
    }

    // MARK: cd

    func testCdToTmpUpdatesEnv() throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"
        try cap.shell.run("cd /tmp")
        XCTAssertEqual(cap.shell.environment.workingDirectory, "/tmp")
        XCTAssertEqual(cap.shell.environment["PWD"], "/tmp")
        XCTAssertEqual(cap.shell.environment["OLDPWD"], "/")
    }

    func testCdToMissingDirectoryFailsWithStderr() throws {
        let cap = CapturingShell()
        let status = try cap.shell.run("cd /this/definitely/does/not/exist")
        XCTAssertEqual(status, .failure)
        XCTAssertTrue(cap.stderr.contains("cd"), cap.stderr)
    }

    func testCdWithNoArgGoesToHome() throws {
        let cap = CapturingShell()
        cap.shell.environment["HOME"] = "/tmp"
        cap.shell.environment.workingDirectory = "/"
        try cap.shell.run("cd")
        XCTAssertEqual(cap.shell.environment.workingDirectory, "/tmp")
    }

    func testCdDashGoesBackToOldpwd() throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"
        try cap.shell.run("cd /tmp")
        try cap.shell.run("cd -")
        XCTAssertEqual(cap.shell.environment.workingDirectory, "/")
    }

    // MARK: export / unset

    func testExportSetsVariable() throws {
        let cap = CapturingShell()
        try cap.shell.run("export GREETING=hello")
        XCTAssertEqual(cap.shell.environment["GREETING"], "hello")
    }

    func testExportWithEmptyValue() throws {
        let cap = CapturingShell()
        try cap.shell.run("export X=")
        XCTAssertEqual(cap.shell.environment["X"], "")
    }

    func testUnsetRemovesVariable() throws {
        let cap = CapturingShell()
        cap.shell.environment["FOO"] = "bar"
        try cap.shell.run("unset FOO")
        XCTAssertNil(cap.shell.environment["FOO"])
    }

    func testExportThenEchoRoundtrips() throws {
        let cap = CapturingShell()
        try cap.shell.run("export NAME=oliver")
        try cap.shell.run("echo $NAME")
        XCTAssertEqual(cap.stdout, "oliver\n")
    }

    // MARK: assignments

    func testStandaloneAssignmentSetsVariable() throws {
        let cap = CapturingShell()
        try cap.shell.run("X=hello")
        XCTAssertEqual(cap.shell.environment["X"], "hello")
    }

    func testAssignmentPrefixIsScoped() throws {
        // Match bash: `$X` is expanded *before* the prefix assignment is
        // applied, so `echo` sees "outer"; but the scoped assignment must
        // not leak into the shell's env afterwards.
        let cap = CapturingShell()
        cap.shell.environment["X"] = "outer"
        try cap.shell.run("X=inner echo $X")
        XCTAssertEqual(cap.stdout, "outer\n",
                       "$X expands with pre-prefix value, matching bash")
        XCTAssertEqual(cap.shell.environment["X"], "outer",
                       "scoped assignment must not leak back into env")
    }

    // MARK: exit

    func testExitReturnsStatus() throws {
        let cap = CapturingShell()
        let status = try cap.shell.run("exit 7")
        XCTAssertEqual(status.code, 7)
    }

    func testExitStopsSubsequentCommands() throws {
        let cap = CapturingShell()
        try cap.shell.run("exit 3; echo should-not-run")
        XCTAssertEqual(cap.stdout, "")
    }
}
