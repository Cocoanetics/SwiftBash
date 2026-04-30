import Testing
@testable import BashInterpreter

@Suite struct BuiltinsTests {

    // MARK: true / false / :

    @Test func trueAndFalse() async throws {
        let cap = CapturingShell()
        #expect(try await cap.shell.run("true") == .success)
        #expect(try await cap.shell.run("false") == .failure)
    }

    @Test func colonIsSuccess() async throws {
        let cap = CapturingShell()
        #expect(try await cap.shell.run(": whatever") == .success)
        #expect(cap.stdout == "")
    }

    // MARK: pwd

    @Test func pwdPrintsWorkingDirectory() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/tmp"
        try await cap.shell.run("pwd")
        #expect(cap.stdout == "/tmp\n")
    }

    // MARK: cd

    #if !os(Windows)
    @Test func cdToTmpUpdatesEnv() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"
        try await cap.shell.run("cd /tmp")
        #expect(cap.shell.environment.workingDirectory == "/tmp")
        #expect(cap.shell.environment["PWD"] == "/tmp")
        #expect(cap.shell.environment["OLDPWD"] == "/")
    }
    #endif

    @Test func cdToMissingDirectoryFailsWithStderr() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("cd /this/definitely/does/not/exist")
        #expect(status == .failure)
        #expect(cap.stderr.contains("cd"), "\(cap.stderr)")
    }

    #if !os(Windows)
    @Test func cdWithNoArgGoesToHome() async throws {
        let cap = CapturingShell()
        cap.shell.environment["HOME"] = "/tmp"
        cap.shell.environment.workingDirectory = "/"
        try await cap.shell.run("cd")
        #expect(cap.shell.environment.workingDirectory == "/tmp")
    }
    #endif

    @Test func cdDashGoesBackToOldpwd() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"
        try await cap.shell.run("cd /tmp")
        try await cap.shell.run("cd -")
        #expect(cap.shell.environment.workingDirectory == "/")
    }

    // MARK: export / unset

    @Test func exportSetsVariable() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("export GREETING=hello")
        #expect(cap.shell.environment["GREETING"] == "hello")
    }

    @Test func exportWithEmptyValue() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("export X=")
        #expect(cap.shell.environment["X"] == "")
    }

    @Test func unsetRemovesVariable() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FOO"] = "bar"
        try await cap.shell.run("unset FOO")
        #expect(cap.shell.environment["FOO"] == nil)
    }

    @Test func exportThenEchoRoundtrips() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("export NAME=oliver")
        try await cap.shell.run("echo $NAME")
        #expect(cap.stdout == "oliver\n")
    }

    // MARK: assignments

    @Test func standaloneAssignmentSetsVariable() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("X=hello")
        #expect(cap.shell.environment["X"] == "hello")
    }

    @Test func assignmentPrefixIsScoped() async throws {
        // Match bash: `$X` is expanded *before* the prefix assignment is
        // applied, so `echo` sees "outer"; but the scoped assignment must
        // not leak into the shell's env afterwards.
        let cap = CapturingShell()
        cap.shell.environment["X"] = "outer"
        try await cap.shell.run("X=inner echo $X")
        #expect(cap.stdout == "outer\n",
                "$X expands with pre-prefix value, matching bash")
        #expect(cap.shell.environment["X"] == "outer",
                "scoped assignment must not leak back into env")
    }

    // MARK: exit

    @Test func exitReturnsStatus() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("exit 7")
        #expect(status.code == 7)
    }

    @Test func exitStopsSubsequentCommands() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("exit 3; echo should-not-run")
        #expect(cap.stdout == "")
    }
}
