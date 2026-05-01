import Testing
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct EnvironmentTests {

    @Test func initWithDictionary() {
        let env = Environment(variables: ["FOO": "bar", "BAZ": "qux"])
        #expect(env["FOO"] == "bar")
        #expect(env["BAZ"] == "qux")
    }

    @Test func subscriptAssignment() {
        var env = Environment()
        env["X"] = "y"
        #expect(env["X"] == "y")
        env["X"] = nil
        #expect(env["X"] == nil)
    }

    #if !os(Windows)
    @Test func currentLoadsFromProcess() {
        let env = Environment.current()
        // PATH is essentially always present on macOS/Linux.
        #expect(env["PATH"] != nil)
        #expect(!env.workingDirectory.isEmpty)
    }
    #endif

    @Test func shellReadsEnvironmentDictionary() async throws {
        let cap = CapturingShell(environment:
            Environment(variables: ["PATH": "/usr/bin:/bin",
                                    "USER": "oliver"]))
        try await cap.shell.run("echo $USER $PATH")
        #expect(cap.stdout == "oliver /usr/bin:/bin\n")
    }
}
#endif
