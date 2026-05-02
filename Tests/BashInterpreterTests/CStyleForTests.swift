import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct CStyleForTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    @Test func basicCounting() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=0; i<3; i++)); do
                echo "i=$i"
            done
            """)
        #expect(cap.stdout == "i=0\ni=1\ni=2\n")
    }

    @Test func decrement() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=3; i>0; i--)); do
                echo "$i"
            done
            """)
        #expect(cap.stdout == "3\n2\n1\n")
    }

    @Test func customStep() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=0; i<10; i+=3)); do
                echo "$i"
            done
            """)
        #expect(cap.stdout == "0\n3\n6\n9\n")
    }

    @Test func emptyCondIsInfiniteWithBreak() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            i=0
            for ((;;)); do
                if ((i >= 3)); then break; fi
                echo "$i"
                ((i++))
            done
            """)
        #expect(cap.stdout == "0\n1\n2\n")
    }

    @Test func emptyInitUsesPriorVar() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            i=10
            for ((; i<13; i++)); do
                echo "$i"
            done
            """)
        #expect(cap.stdout == "10\n11\n12\n")
    }

    @Test func emptyUpdateMutatesInBody() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=0; i<3;)); do
                echo "$i"
                ((i++))
            done
            """)
        #expect(cap.stdout == "0\n1\n2\n")
    }

    @Test func zeroIterations() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=5; i<5; i++)); do
                echo "no"
            done
            echo "after"
            """)
        #expect(cap.stdout == "after\n")
    }

    @Test func continueSkipsToUpdate() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=0; i<5; i++)); do
                if ((i == 2)); then continue; fi
                echo "$i"
            done
            """)
        #expect(cap.stdout == "0\n1\n3\n4\n")
    }

    @Test func breakStopsLoop() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=0; i<10; i++)); do
                if ((i == 3)); then break; fi
                echo "$i"
            done
            """)
        #expect(cap.stdout == "0\n1\n2\n")
    }

    @Test func nestedCStyleFor() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=0; i<2; i++)); do
                for ((j=0; j<2; j++)); do
                    echo "$i,$j"
                done
            done
            """)
        #expect(cap.stdout == "0,0\n0,1\n1,0\n1,1\n")
    }

    @Test func breakNLevels() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=0; i<3; i++)); do
                for ((j=0; j<3; j++)); do
                    if ((j == 1)); then break 2; fi
                    echo "$i,$j"
                done
            done
            echo "end"
            """)
        #expect(cap.stdout == "0,0\nend\n")
    }

    @Test func iVisibleAfterLoop() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=0; i<3; i++)); do :; done
            echo "$i"
            """)
        #expect(cap.stdout == "3\n")
    }

    @Test func multipleCommaSeparated() async throws {
        // Bash supports comma in arithmetic — `for ((i=0,j=10; i<3; i++,j--))`
        // declares two loop vars at once.
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=0,j=10; i<3; i++,j--)); do
                echo "$i $j"
            done
            """)
        #expect(cap.stdout == "0 10\n1 9\n2 8\n")
    }

    @Test func feedsPipeline() async throws {
        // Drain a C-style for through `read` to confirm the loop is
        // wired into the pipeline plumbing.
        let cap = makeShell()
        try await cap.shell.run("""
            for ((i=1; i<=3; i++)); do echo "$i"; done | { read a; read b; echo "$a $b"; }
            """)
        #expect(cap.stdout == "1 2\n")
    }
}
