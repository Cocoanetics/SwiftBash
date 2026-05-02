import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct LoopControlTests {

    // MARK: break

    @Test func breakExitsWhile() async throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        try await cap.shell.run("""
            while (( i < 10 )); do
              if (( i == 3 )); then break; fi
              echo $i
              (( i++ ))
            done
            """)
        #expect(cap.stdout == "0\n1\n2\n")
        #expect(cap.shell.environment["i"] == "3")
    }

    @Test func breakExitsForArithCondition() async throws {
        let cap = CapturingShell()
        cap.shell.environment["n"] = "0"
        try await cap.shell.run("""
            for x in 1 2 3 4 5; do
              (( x == 3 )) && break
              echo $x
            done
            """)
        #expect(cap.stdout == "1\n2\n")
    }

    @Test func breakTwoLevels() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            for a in 1 2 3; do
              for b in 1 2 3; do
                echo $a.$b
                (( a == 1 && b == 2 )) && break 2
              done
            done
            """)
        #expect(cap.stdout == "1.1\n1.2\n")
    }

    // MARK: continue

    @Test func continueSkipsIteration() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            for x in 1 2 3 4 5; do
              (( x == 3 )) && continue
              echo $x
            done
            """)
        #expect(cap.stdout == "1\n2\n4\n5\n")
    }

    @Test func continueInWhile() async throws {
        let cap = CapturingShell()
        cap.shell.environment["i"] = "0"
        try await cap.shell.run("""
            while (( i < 5 )); do
              (( i++ ))
              (( i == 3 )) && continue
              echo $i
            done
            """)
        #expect(cap.stdout == "1\n2\n4\n5\n")
    }

    @Test func continueTwoLevels() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            for a in 1 2 3; do
              for b in 1 2 3; do
                (( a == 2 && b == 1 )) && continue 2
                echo $a.$b
              done
            done
            """)
        // Inner loop runs 1.1 1.2 1.3 for a=1, then for a=2 it immediately
        // continues the outer, skipping 2.*, then 3.1 3.2 3.3.
        #expect(cap.stdout == "1.1\n1.2\n1.3\n3.1\n3.2\n3.3\n")
    }

    // MARK: Edge cases

    @Test func breakZeroIsAnError() async {
        let cap = CapturingShell()
        await #expect(throws: (any Error).self) {
            try await cap.shell.run("""
                for x in a; do break 0; done
                """)
        }
    }

    @Test func strayBreakWarnsAndContinues() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("break; echo after")
        #expect(status == .success)
        #expect(cap.stdout == "after\n")
        #expect(cap.stderr.contains("only meaningful"), "\(cap.stderr)")
    }

    @Test func strayContinueWarns() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("continue")
        #expect(cap.stderr.contains("only meaningful"), "\(cap.stderr)")
    }

    // MARK: Exit status

    @Test func breakReturnsSuccess() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("for x in 1; do break; done")
        #expect(status == .success)
    }
}
