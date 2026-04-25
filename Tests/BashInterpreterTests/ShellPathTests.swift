import Testing
@testable import BashInterpreter

@Suite struct ShellPathTests {

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
        let shell = Shell(stdout: .discard, stderr: .discard)
        shell.environment.workingDirectory = "/"
        #expect(shell.resolvePath("~") == "/~")
    }
}
