import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct ShellPathTests {

    private func makeShell() -> Shell {
        let shell = Shell(stdout: .discard, stderr: .discard)
        shell.environment.workingDirectory = "/home/oliver"
        shell.environment["HOME"] = "/home/oliver"
        return shell
    }

    @Test func absolutePathUnchanged() {
        let shell = makeShell()
        #expect(shell.resolvePath("/etc/passwd") == "/etc/passwd")
    }

    @Test func relativeResolvesAgainstCwd() {
        let shell = makeShell()
        #expect(shell.resolvePath("notes.txt") == "/home/oliver/notes.txt")
    }

    @Test func dotDotNormalised() {
        let shell = makeShell()
        #expect(shell.resolvePath("../root") == "/home/root")
    }

    @Test func tildeExpandsToHome() {
        let shell = makeShell()
        #expect(shell.resolvePath("~") == "/home/oliver")
        #expect(shell.resolvePath("~/docs") == "/home/oliver/docs")
    }

    @Test func bareTildeWithoutHomeReturnsVerbatim() {
        // Shell.init now seeds HOME with a synthetic default, so we
        // have to explicitly clear it to simulate a no-HOME shell —
        // a state that's mainly hit when the embedder strips it
        // intentionally.
        let shell = Shell(stdout: .discard, stderr: .discard)
        shell.environment.workingDirectory = "/"
        shell.environment.variables.removeValue(forKey: "HOME")
        #expect(shell.resolvePath("~") == "/~")
    }
}
