import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct GroupSubshellTests {

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

    @Test func subshellAssignmentDoesNotLeak() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("(X=inside); echo after=$X")
        #expect(cap.stdout == "after=\n",
                "subshell mutations stay local — outer X is still unset")
        #expect(cap.shell.environment["X"] == nil)
    }

    @Test func subshellSeesOuterEnvironment() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "outer"
        try await cap.shell.run("(echo $X)")
        #expect(cap.stdout == "outer\n")
    }

    @Test func subshellCdDoesNotLeak() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"
        try await cap.shell.run("(cd /tmp); pwd")
        #expect(cap.stdout == "/\n",
                "cd inside the subshell stays local")
    }

    @Test func subshellExitStatusPropagates() async throws {
        let cap = CapturingShell()
        let s1 = try await cap.shell.run("(true)")
        #expect(s1 == .success)
        let s2 = try await cap.shell.run("(false)")
        #expect(s2 == .failure)
        #expect(cap.shell.lastExitStatus == .failure)
    }

    @Test func subshellUnsetDoesNotLeak() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "outer"
        try await cap.shell.run("(unset X); echo $X")
        #expect(cap.stdout == "outer\n")
    }

    @Test func subshellInheritsCommandsAndFileSystem() async throws {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        try await cap.shell.fileSystem.createDirectory("/work", intermediates: true)
        cap.shell.environment.workingDirectory = "/work"
        cap.shell.register(name: "greet") { _ in
            Shell.current.stdout("hi from registered cmd\n")
            return .success
        }
        try await cap.shell.run("(greet)")
        #expect(cap.stdout == "hi from registered cmd\n")
    }

    @Test func groupAssignmentVisible() async throws {
        // Groups DO share the shell's env (matching bash).
        let cap = CapturingShell()
        try await cap.shell.run("{ X=inside; }; echo $X")
        #expect(cap.stdout == "inside\n")
    }
}
