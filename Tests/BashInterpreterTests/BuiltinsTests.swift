import XCTest
@testable import BashInterpreter

final class BuiltinsTests: XCTestCase {

    // MARK: true / false / :

    func testTrueAndFalse() async throws {
        let cap = CapturingShell()
        do { let _s = try await cap.shell.run("true"); XCTAssertEqual(_s, .success) }
        do { let _s = try await cap.shell.run("false"); XCTAssertEqual(_s, .failure) }
    }

    func testColonIsSuccess() async throws {
        let cap = CapturingShell()
        do { let _s = try await cap.shell.run(": whatever"); XCTAssertEqual(_s, .success) }
        XCTAssertEqual(cap.stdout, "")
    }

    // MARK: pwd

    func testPwdPrintsWorkingDirectory() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/tmp"
        try await cap.shell.run("pwd")
        XCTAssertEqual(cap.stdout, "/tmp\n")
    }

    // MARK: cd

    func testCdToTmpUpdatesEnv() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"
        try await cap.shell.run("cd /tmp")
        XCTAssertEqual(cap.shell.environment.workingDirectory, "/tmp")
        XCTAssertEqual(cap.shell.environment["PWD"], "/tmp")
        XCTAssertEqual(cap.shell.environment["OLDPWD"], "/")
    }

    func testCdToMissingDirectoryFailsWithStderr() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("cd /this/definitely/does/not/exist")
        XCTAssertEqual(status, .failure)
        XCTAssertTrue(cap.stderr.contains("cd"), cap.stderr)
    }

    func testCdWithNoArgGoesToHome() async throws {
        let cap = CapturingShell()
        cap.shell.environment["HOME"] = "/tmp"
        cap.shell.environment.workingDirectory = "/"
        try await cap.shell.run("cd")
        XCTAssertEqual(cap.shell.environment.workingDirectory, "/tmp")
    }

    func testCdDashGoesBackToOldpwd() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"
        try await cap.shell.run("cd /tmp")
        try await cap.shell.run("cd -")
        XCTAssertEqual(cap.shell.environment.workingDirectory, "/")
    }

    // MARK: export / unset

    func testExportSetsVariable() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("export GREETING=hello")
        XCTAssertEqual(cap.shell.environment["GREETING"], "hello")
    }

    func testExportWithEmptyValue() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("export X=")
        XCTAssertEqual(cap.shell.environment["X"], "")
    }

    func testUnsetRemovesVariable() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FOO"] = "bar"
        try await cap.shell.run("unset FOO")
        XCTAssertNil(cap.shell.environment["FOO"])
    }

    func testExportThenEchoRoundtrips() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("export NAME=oliver")
        try await cap.shell.run("echo $NAME")
        XCTAssertEqual(cap.stdout, "oliver\n")
    }

    // MARK: assignments

    func testStandaloneAssignmentSetsVariable() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("X=hello")
        XCTAssertEqual(cap.shell.environment["X"], "hello")
    }

    func testAssignmentPrefixIsScoped() async throws {
        // Match bash: `$X` is expanded *before* the prefix assignment is
        // applied, so `echo` sees "outer"; but the scoped assignment must
        // not leak into the shell's env afterwards.
        let cap = CapturingShell()
        cap.shell.environment["X"] = "outer"
        try await cap.shell.run("X=inner echo $X")
        XCTAssertEqual(cap.stdout, "outer\n",
                       "$X expands with pre-prefix value, matching bash")
        XCTAssertEqual(cap.shell.environment["X"], "outer",
                       "scoped assignment must not leak back into env")
    }

    // MARK: exit

    func testExitReturnsStatus() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("exit 7")
        XCTAssertEqual(status.code, 7)
    }

    func testExitStopsSubsequentCommands() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("exit 3; echo should-not-run")
        XCTAssertEqual(cap.stdout, "")
    }
}
