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

    // The lexical normaliser behind `resolvePath` is inherited from
    // `ShellKit.Shell.normalizePath`. These pin the parts SwiftBash
    // leans on, so a ShellKit bump that changes them fails here.

    @Test func dotDotClampsAtRoot() {
        // bash: `cd /..` lands on `/`. Mount routing and the symlink
        // target sanitiser rely on a `../..` chain never climbing
        // above the root.
        let shell = makeShell()
        #expect(shell.resolvePath("/..") == "/")
        #expect(shell.resolvePath("../../../../etc") == "/etc")
    }

    @Test func repeatedSlashesAndDotsCollapse() {
        let shell = makeShell()
        #expect(shell.resolvePath("/a//./b/") == "/a/b")
    }

    #if os(Windows)
    @Test func driveLetterIsTheRootSegment() {
        // `..` collapses beneath the drive and stops there; separators
        // come back as `/`.
        let shell = makeShell()
        #expect(shell.resolvePath(#"C:\Users\foo\..\bar"#) == "C:/Users/bar")
        #expect(shell.resolvePath(#"C:\.."#) == "C:/")
    }
    #endif

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
