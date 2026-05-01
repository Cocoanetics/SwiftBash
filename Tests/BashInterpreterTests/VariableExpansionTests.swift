import Testing
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct VariableExpansionTests {

    @Test func echoPath() async throws {
        let cap = CapturingShell()
        cap.shell.environment["PATH"] = "/usr/bin:/bin"
        try await cap.shell.run("echo $PATH")
        #expect(cap.stdout == "/usr/bin:/bin\n")
    }

    @Test func echoUndefinedVariableYieldsEmpty() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $NOPE")
        #expect(cap.stdout == "\n")
    }

    @Test func bracedExpansion() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run("echo ${NAME}")
        #expect(cap.stdout == "oliver\n")
    }

    @Test func expansionInsideDoubleQuotes() async throws {
        let cap = CapturingShell()
        cap.shell.environment["WHO"] = "world"
        try await cap.shell.run(#"echo "hello $WHO""#)
        #expect(cap.stdout == "hello world\n")
    }

    @Test func noExpansionInsideSingleQuotes() async throws {
        let cap = CapturingShell()
        cap.shell.environment["WHO"] = "world"
        try await cap.shell.run("echo 'hello $WHO'")
        #expect(cap.stdout == "hello $WHO\n")
    }

    @Test func commandSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $(echo inner)")
        #expect(cap.stdout == "inner\n")
    }

    @Test func nestedCommandSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $(echo $(echo deep))")
        #expect(cap.stdout == "deep\n")
    }

    @Test func commandSubstitutionInsideString() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run(#"echo "hi $(echo $NAME)""#)
        #expect(cap.stdout == "hi oliver\n")
    }

    @Test func tildeExpandsToHome() async throws {
        let cap = CapturingShell()
        cap.shell.environment["HOME"] = "/Users/oliver"
        try await cap.shell.run("echo ~/docs")
        #expect(cap.stdout == "/Users/oliver/docs\n")
    }

    @Test func dollarQuestionIsLastExitStatus() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("false; echo $?")
        #expect(cap.stdout == "1\n")
    }

    @Test func adjacentVarsConcatenate() async throws {
        let cap = CapturingShell()
        cap.shell.environment["A"] = "foo"
        cap.shell.environment["B"] = "bar"
        try await cap.shell.run("echo $A$B")
        #expect(cap.stdout == "foobar\n")
    }
}
#endif
