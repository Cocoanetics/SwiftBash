import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct EchoTests {

    @Test func noArgs() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo")
        #expect(cap.stdout == "\n")
    }

    @Test func singleArg() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo hi")
        #expect(cap.stdout == "hi\n")
    }

    @Test func multipleArgsJoinedWithSpace() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo a b c")
        #expect(cap.stdout == "a b c\n")
    }

    @Test func dashNSuppressesNewline() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo -n hello")
        #expect(cap.stdout == "hello")
    }

    @Test func doubleDashIsPrintedLikeBash() async throws {
        // bash's echo has no end-of-options marker.
        let cap = CapturingShell()
        try await cap.shell.run("echo --; echo -- -n literal; echo -n -- x; echo")
        #expect(cap.stdout == "--\n-- -n literal\n-- x\n")
    }

    @Test func quotesAreStripped() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "hello world""#)
        #expect(cap.stdout == "hello world\n")
    }

    @Test func singleQuotesPreserveDollars() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "expanded"
        try await cap.shell.run("echo '$X'")
        #expect(cap.stdout == "$X\n")
    }
}
