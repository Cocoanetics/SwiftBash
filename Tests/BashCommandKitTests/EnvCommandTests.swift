import Testing
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct EnvCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(EnvCommand.self)
        return cap
    }

    @Test func emptyEnvPrintsNothing() async throws {
        let cap = makeShell()
        cap.shell.environment.variables = [:]
        try await cap.shell.run("env")
        #expect(cap.stdout == "")
    }

    @Test func printsAllSortedByName() async throws {
        let cap = makeShell()
        cap.shell.environment.variables = [
            "ZEBRA": "z", "ALPHA": "a", "BRAVO": "b"
        ]
        try await cap.shell.run("env")
        #expect(cap.stdout == "ALPHA=a\nBRAVO=b\nZEBRA=z\n")
    }

    @Test func reflectsExportedVariables() async throws {
        let cap = makeShell()
        cap.shell.environment.variables = [:]
        try await cap.shell.run("export FOO=bar")
        try await cap.shell.run("env")
        #expect(cap.stdout == "FOO=bar\n")
    }
}
#endif
