import Testing
@testable import BashInterpreter

/// End-to-end coverage that `$1`, `$2`, … work inside `$((…))` and
/// `((…))` — both as the shell expands them via `positionalParameters`.
@Suite(.timeLimit(.minutes(1))) struct PositionalParamsInArithmeticTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        return cap
    }

    @Test func dollarOnePlusLiteral() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["10"]
        try await cap.shell.run(#"echo $(( $1 + 5 ))"#)
        #expect(cap.stdout == "15\n")
    }

    @Test func dollarOneToDollarNine() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["1", "2", "3", "4", "5",
                                          "6", "7", "8", "9"]
        try await cap.shell.run(
            #"echo $(( $1 + $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9 ))"#)
        #expect(cap.stdout == "45\n")
    }

    @Test func unsetParamIsZero() async throws {
        let cap = makeShell()
        // No positional params → $1 expands to "" → evaluator treats as 0
        try await cap.shell.run(#"echo $(( $1 + 7 ))"#)
        #expect(cap.stdout == "7\n")
    }

    @Test func recursionWithPositionalArith() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            countdown() {
              if [ "$1" -le 0 ]; then return; fi
              echo "$1"
              countdown $(( $1 - 1 ))
            }
            countdown 3
            """)
        #expect(cap.stdout == "3\n2\n1\n")
    }

    @Test func arithCommandWithDollarOne() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["7"]
        try await cap.shell.run(#"(( $1 > 5 )) && echo big"#)
        #expect(cap.stdout == "big\n")
    }

    @Test func multiDigitPositionalNeedsBraces() async throws {
        // Matches bash: `$10` (unbraced) is `$1` followed by literal
        // `0`, NOT positional[10]. Use `${10}` in arithmetic to get
        // positional[10].
        let cap = makeShell()
        cap.shell.positionalParameters =
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "100"]
        try await cap.shell.run(#"echo $(( ${10} + 1 ))"#)
        #expect(cap.stdout == "101\n")
    }

    @Test func bracedDefaultInArithmetic() async throws {
        let cap = makeShell()
        // ${MISSING:-7} substitutes to "7" inside the arith body.
        try await cap.shell.run(#"echo $(( ${MISSING:-7} * 6 ))"#)
        #expect(cap.stdout == "42\n")
    }

    @Test func bracedSubstringInArithmetic() async throws {
        let cap = makeShell()
        cap.shell.environment["S"] = "abcdef"
        // ${#S} expands to 6 first, then 6 + 4 = 10.
        try await cap.shell.run(#"echo $(( ${#S} + 4 ))"#)
        #expect(cap.stdout == "10\n")
    }
}
