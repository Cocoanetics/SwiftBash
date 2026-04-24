import Testing
@testable import BashInterpreter

@Suite struct WhileUntilTests {

    // MARK: while

    @Test func whileFalseNeverRuns() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("while false; do echo nope; done")
        #expect(cap.stdout == "")
    }

    @Test func whileArithmeticCounter() async throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        try await cap.shell.run("while (( i < 3 )); do echo $i; (( i++ )); done")
        #expect(cap.stdout == "0\n1\n2\n")
        #expect(cap.shell.environment["i"] == "3")
    }

    @Test func whileExitStatusIsLastBody() async throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        let status = try await cap.shell.run(
            "while (( i < 1 )); do (( i++ )); false; done"
        )
        #expect(status == .failure)
    }

    // MARK: until

    @Test func untilRunsUntilConditionSucceeds() async throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        try await cap.shell.run("until (( i >= 3 )); do echo $i; (( i++ )); done")
        #expect(cap.stdout == "0\n1\n2\n")
    }

    @Test func untilTrueNeverRuns() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("until true; do echo nope; done")
        #expect(cap.stdout == "")
    }

    // MARK: Variable accumulation

    @Test func loopAccumulatesInEnv() async throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "0"
        cap.shell.environment["sum"] = "0"
        try await cap.shell.run("""
            while (( n < 4 )); do
              (( sum = sum + n ))
              (( n++ ))
            done
            """)
        #expect(cap.shell.environment["sum"] == "6") // 0+1+2+3
    }
}
