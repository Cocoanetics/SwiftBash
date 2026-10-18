import Testing
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct EnvCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.install(EnvCommand.self)
        return cap
    }

    @Test func emptyEnvPrintsNothing() async throws {
        let cap = makeShell()
        // Preserve PATH so `env` resolves; reset everything else. Like
        // bash, the shell exports `_` as the command's path.
        cap.shell.environment.variables = ["PATH": "/usr/bin:/bin"]
        try await cap.shell.run("env")
        #expect(cap.stdout == "PATH=/usr/bin:/bin\n_=/usr/bin/env\n")
    }

    @Test func printsAllSortedByName() async throws {
        let cap = makeShell()
        cap.shell.environment.variables = [
            "PATH": "/usr/bin:/bin",
            "ZEBRA": "z", "ALPHA": "a", "BRAVO": "b"
        ]
        try await cap.shell.run("env")
        #expect(cap.stdout
            == "ALPHA=a\nBRAVO=b\nPATH=/usr/bin:/bin\nZEBRA=z\n_=/usr/bin/env\n")
    }

    @Test func reflectsExportedVariables() async throws {
        let cap = makeShell()
        cap.shell.environment.variables = ["PATH": "/usr/bin:/bin"]
        try await cap.shell.run("export FOO=bar")
        try await cap.shell.run("env")
        #expect(cap.stdout == "FOO=bar\nPATH=/usr/bin:/bin\n_=/usr/bin/env\n")
    }
}
