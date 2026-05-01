import Testing
@testable import BashInterpreter

#if !os(Android)
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

    @Test func doubleDashEndsOptions() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo -- -n literal")
        #expect(cap.stdout == "-n literal\n")
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
#endif
