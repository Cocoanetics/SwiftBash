import Testing
@testable import BashInterpreter

@Suite struct GroupSubshellTests {

    @Test func groupRunsAllCommands() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("{ echo a; echo b; echo c; }")
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func groupExitStatusIsLast() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("{ true; false; }")
        #expect(status == .failure)
    }

    @Test func subshellRunsCommands() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("(echo a; echo b)")
        #expect(cap.stdout == "a\nb\n")
    }

    /// In real bash, a subshell gets an environment copy — changes inside
    /// don't leak back. Without subprocess isolation this skeleton leaks.
    /// Test documents the current (incorrect) behaviour so it's obvious
    /// when we fix it later.
    @Test func subshellAssignmentCurrentlyLeaks() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("(X=inside); echo after=$X")
        #expect(cap.stdout == "after=inside\n",
            "Subshell isolation not yet implemented — this will change once subprocess support lands.")
    }

    @Test func groupAssignmentVisible() async throws {
        // Groups DO share the shell's env (matching bash).
        let cap = CapturingShell()
        try await cap.shell.run("{ X=inside; }; echo $X")
        #expect(cap.stdout == "inside\n")
    }
}
