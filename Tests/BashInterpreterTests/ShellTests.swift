import Testing
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct ShellTests {

    // MARK: Basic smoke

    @Test func echoHelloWorld() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("echo hello world")
        #expect(status == .success)
        #expect(cap.stdout == "hello world\n")
    }

    @Test func emptyInputIsSuccess() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("")
        #expect(status == .success)
        #expect(cap.stdout == "")
    }

    @Test func commandNotFoundReturns127() async throws {
        // Bash behaviour: print to stderr, set $? = 127, keep going.
        // The script must not abort, so chained `cmd || …` works.
        let cap = CapturingShell()
        try await cap.shell.run("nosuchcommand")
        #expect(cap.shell.lastExitStatus.code == 127)
        #expect(cap.stderr.contains("nosuchcommand: command not found"))
    }

    @Test func lastExitStatusTracksCommands() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("true")
        #expect(cap.shell.lastExitStatus == .success)
        try await cap.shell.run("false")
        #expect(cap.shell.lastExitStatus == .failure)
    }
}
#endif
