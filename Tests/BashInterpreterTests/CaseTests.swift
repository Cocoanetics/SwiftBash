import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct CaseTests {

    // MARK: Basic matching

    @Test func literalMatch() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case apple in
              apple) echo fruit;;
              carrot) echo veg;;
            esac
            """)
        #expect(cap.stdout == "fruit\n")
    }

    @Test func fallsThroughToSecondArm() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case carrot in
              apple) echo fruit;;
              carrot) echo veg;;
            esac
            """)
        #expect(cap.stdout == "veg\n")
    }

    @Test func noMatchProducesNoOutput() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case banana in
              apple) echo one;;
              carrot) echo two;;
            esac
            """)
        #expect(cap.stdout == "")
    }

    // MARK: Glob patterns

    @Test func starMatchesAnything() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case hello in
              hi) echo short;;
              *) echo anything;;
            esac
            """)
        #expect(cap.stdout == "anything\n")
    }

    @Test func questionMatchesOneChar() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case ab in
              ?) echo one;;
              ??) echo two;;
            esac
            """)
        #expect(cap.stdout == "two\n")
    }

    @Test func charClassMatches() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case m in
              [a-f]) echo early;;
              [g-p]) echo middle;;
              [q-z]) echo late;;
            esac
            """)
        #expect(cap.stdout == "middle\n")
    }

    @Test func multipleAlternativesWithBar() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case green in
              red|orange|yellow) echo warm;;
              green|blue|purple) echo cool;;
            esac
            """)
        #expect(cap.stdout == "cool\n")
    }

    @Test func suffixGlob() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case script.sh in
              *.sh) echo shell;;
              *.py) echo python;;
            esac
            """)
        #expect(cap.stdout == "shell\n")
    }

    // MARK: Fall-through terminators

    @Test func semiAndFallsThrough() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case a in
              a) echo first ;&
              b) echo second;;
              c) echo third;;
            esac
            """)
        #expect(cap.stdout == "first\nsecond\n")
    }

    @Test func semiSemiAndContinuesTesting() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            case abc in
              *b*) echo has-b ;;&
              a*) echo starts-a ;;
              x*) echo starts-x ;;
            esac
            """)
        // First arm matches (contains 'b'). `;;&` means "continue testing".
        // Second arm matches (starts with 'a'), runs, then `;;` stops.
        #expect(cap.stdout == "has-b\nstarts-a\n")
    }

    // MARK: Variable subject

    @Test func expandsSubject() async throws {
        let cap = CapturingShell()
        cap.shell.environment["colour"] = "blue"
        try await cap.shell.run("""
            case $colour in
              red) echo stop;;
              green) echo go;;
              blue) echo cool;;
            esac
            """)
        #expect(cap.stdout == "cool\n")
    }

    // MARK: Exit status

    @Test func caseExitStatusIsLastBody() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("""
            case x in
              x) false;;
            esac
            """)
        #expect(status == .failure)
    }

    @Test func caseWithNoMatchExitsSuccess() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("""
            case z in
              a) false;;
            esac
            """)
        #expect(status == .success)
    }

    // MARK: Empty body

    @Test func armWithNoBodyStillMatches() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("""
            case x in
              x) ;;
              *) echo default;;
            esac
            """)
        #expect(cap.stdout == "")
        #expect(status == .success)
    }
}
