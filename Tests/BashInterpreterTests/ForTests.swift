import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct ForTests {

    @Test func forLiteralList() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("for x in a b c; do echo $x; done")
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func forEmptyListRunsNothing() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("for x in; do echo $x; done")
        #expect(cap.stdout == "")
    }

    @Test func forLeavesVariableAtLastValue() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("for x in a b c; do :; done")
        #expect(cap.shell.environment["x"] == "c")
    }

    @Test func forWithVariableExpansion() async throws {
        let cap = CapturingShell()
        cap.shell.environment["item"] = "widget"
        try await cap.shell.run("for x in one $item; do echo $x; done")
        #expect(cap.stdout == "one\nwidget\n")
    }

    @Test func forExecutesBodyInOrder() async throws {
        let cap = CapturingShell()
        cap.shell.environment["total"] = "0"
        try await cap.shell.run("""
            for n in 1 2 3 4; do
              (( total = total + n ))
            done
            """)
        #expect(cap.shell.environment["total"] == "10")
    }

    @Test func nestedFor() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("""
            for a in x y; do
              for b in 1 2; do
                echo $a$b
              done
            done
            """)
        #expect(cap.stdout == "x1\nx2\ny1\ny2\n")
    }

    @Test func forCommandSubstitutionInList() async throws {
        // Unquoted `$(…)` in the `in` clause is word-split like bash, so
        // this iterates three times.
        let cap = CapturingShell()
        try await cap.shell.run("for x in $(echo a b c); do echo [$x]; done")
        #expect(cap.stdout == "[a]\n[b]\n[c]\n")
    }

    @Test func forWithoutInIteratesPositionalParameters() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["a", "b", "c"]
        try await cap.shell.run("for x; do echo $x; done")
        #expect(cap.stdout == "a\nb\nc\n")
    }
}
