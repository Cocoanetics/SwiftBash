import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct AbsolutePathDispatchTests {

    /// `commandsByPath` is keyed by the canonical absolute path of
    /// an installed command — the path the `BinCatalogOverlay`
    /// synthesises under `/bin` / `/usr/bin`. A registered command
    /// must surface there.
    @Test func resolvesBashAtCanonicalBinPath() async throws {
        let shell = Shell()
        #expect(shell.commandsByPath["/bin/bash"] != nil)
        #expect(shell.commandsByPath["/bin/bash"]?.name == "bash")
    }

    @Test func resolvesTrueAtCanonicalBinPath() async throws {
        let shell = Shell()
        #expect(shell.commandsByPath["/usr/bin/true"] != nil)
    }

    @Test func rejectsNonCanonicalAbsolutePath() async throws {
        let shell = Shell()
        // `bash` lives at `/bin/bash`, not `/usr/bin/bash`. The
        // wrong path must NOT shadow the registered command.
        #expect(shell.commandsByPath["/usr/bin/bash"] == nil)
    }

    @Test func bashVersionViaAbsolutePathRuns() async throws {
        // End-to-end through `Shell.run` — exercising the dispatcher
        // path we just wired (Shell+Run.swift). `/bin/bash --version`
        // should print the banner and exit 0, the way real bash does.
        let cap = CapturingShell()
        let status = try await cap.shell.run("/bin/bash --version")
        #expect(status.isSuccess)
        #expect(cap.stdout.contains("bash"))
    }
}
