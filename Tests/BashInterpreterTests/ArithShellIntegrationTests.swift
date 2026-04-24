import Testing
@testable import BashInterpreter

/// End-to-end tests that exercise `((…))` and `$((…))` through a `Shell`.
@Suite struct ArithShellIntegrationTests {

    // MARK: $((…)) in word expansion

    @Test func echoArithmeticLiteral() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $((1 + 2))")
        #expect(cap.stdout == "3\n")
    }

    @Test func echoArithmeticWithPrecedence() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $((1 + 2 * 3))")
        #expect(cap.stdout == "7\n")
    }

    @Test func echoArithmeticWithVariable() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "10"
        try await cap.shell.run("echo $((X * 2))")
        #expect(cap.stdout == "20\n")
    }

    @Test func echoArithmeticWithUnsetVariableIsZero() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $((UNDEFINED + 1))")
        #expect(cap.stdout == "1\n")
    }

    @Test func echoArithmeticInsideDoubleQuotes() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "result=$((2 + 3)) done""#)
        #expect(cap.stdout == "result=5 done\n")
    }

    @Test func arithmeticExpressionWithHexAndOctal() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $((0xff + 010))")
        #expect(cap.stdout == "263\n")
    }

    // MARK: ((…)) as a command

    @Test func arithCommandSuccessOnNonZero() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("(( 1 + 1 ))")
        #expect(status == .success)
    }

    @Test func arithCommandFailureOnZero() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("(( 0 ))")
        #expect(status == .failure)
    }

    @Test func arithCommandAssignment() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("(( x = 5 + 3 ))")
        #expect(cap.shell.environment["x"] == "8")
    }

    @Test func arithCommandIncrement() async throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "5"
        try await cap.shell.run("(( i++ ))")
        #expect(cap.shell.environment["i"] == "6")
    }

    @Test func arithCommandWithComparison() async throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "10"
        let a = try await cap.shell.run("(( n > 5 ))")
        #expect(a == .success)
        let b = try await cap.shell.run("(( n < 5 ))")
        #expect(b == .failure)
    }

    @Test func arithCommandInAndChain() async throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "7"
        try await cap.shell.run("(( n > 5 )) && echo big")
        #expect(cap.stdout == "big\n")
    }

    @Test func arithCommandInOrChain() async throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "3"
        try await cap.shell.run("(( n > 5 )) || echo small")
        #expect(cap.stdout == "small\n")
    }

    // MARK: Dollar-question after arithmetic

    @Test func exitStatusOfArithCommand() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("(( 0 ))")
        #expect(cap.shell.lastExitStatus == .failure)
        try await cap.shell.run("(( 42 ))")
        #expect(cap.shell.lastExitStatus == .success)
    }

    // MARK: Combining arithmetic substitution with other features

    @Test func arithSubWithCommandSubstitution() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "4"
        try await cap.shell.run(#"echo $(echo $((X * X)))"#)
        #expect(cap.stdout == "16\n")
    }

    @Test func arithSubExportAndReuse() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("export N=10")
        try await cap.shell.run("echo $((N + N))")
        #expect(cap.stdout == "20\n")
    }

    // MARK: Error propagation

    @Test func divisionByZeroPropagatesAsError() async {
        let cap = CapturingShell()
        let err = await #expect(throws: (any Error).self) {
            try await cap.shell.run("echo $((1/0))")
        }
        #expect(err is ArithError || err is BashInterpreterError,
                "got \(String(describing: err))")
    }

    @Test func syntaxErrorInArithmetic() async {
        let cap = CapturingShell()
        await #expect(throws: (any Error).self) {
            try await cap.shell.run("echo $((1 +))")
        }
    }
}
