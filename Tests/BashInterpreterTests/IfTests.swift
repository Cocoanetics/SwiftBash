import Testing
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct IfTests {

    @Test func ifTrueRunsBody() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("if true; then echo yes; fi")
        #expect(cap.stdout == "yes\n")
    }

    @Test func ifFalseSkipsBody() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("if false; then echo nope; fi")
        #expect(cap.stdout == "")
    }

    @Test func ifElse() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("if false; then echo yes; else echo no; fi")
        #expect(cap.stdout == "no\n")
    }

    @Test func elifFirstBranchHits() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            if true; then echo one
            elif true; then echo two
            else echo three
            fi
            """)
        #expect(cap.stdout == "one\n")
    }

    @Test func elifSecondBranchHits() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            if false; then echo one
            elif true; then echo two
            else echo three
            fi
            """)
        #expect(cap.stdout == "two\n")
    }

    @Test func elseFallsThrough() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            if false; then echo one
            elif false; then echo two
            else echo three
            fi
            """)
        #expect(cap.stdout == "three\n")
    }

    @Test func ifWithArithmeticCondition() async throws {
        let cap = CapturingShell()
        cap.shell.environment["x"] = "10"
        try await cap.shell.run("if (( x > 5 )); then echo big; else echo small; fi")
        #expect(cap.stdout == "big\n")
    }

    @Test func ifExitStatusIsLastRunCommand() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("if true; then false; fi")
        #expect(status == .failure)
    }

    @Test func ifNoMatchReturnsSuccess() async throws {
        // No else clause and condition is false → exit 0 per bash.
        let cap = CapturingShell()
        let status = try await cap.shell.run("if false; then echo nope; fi")
        #expect(status == .success)
    }

    @Test func ifInsideIf() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            if true; then
              if false; then echo inner-yes
              else echo inner-no
              fi
            fi
            """)
        #expect(cap.stdout == "inner-no\n")
    }
}
#endif
