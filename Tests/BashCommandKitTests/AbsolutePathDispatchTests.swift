import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct AbsolutePathDispatchTests {

    /// `commandForCatalogPath` returns the registered command for the
    /// canonical absolute path of a registered builtin — the path the
    /// `BinCatalogOverlay` synthesises under `/bin` / `/usr/bin`.
    @Test func resolvesBashAtCanonicalBinPath() async throws {
        let shell = Shell()
        let cmd = shell.commandForCatalogPath("/bin/bash")
        #expect(cmd != nil)
        #expect(cmd?.name == "bash")
    }

    @Test func resolvesTrueAtCanonicalBinPath() async throws {
        let shell = Shell()
        let cmd = shell.commandForCatalogPath("/usr/bin/true")
        #expect(cmd != nil)
    }

    @Test func rejectsNonCanonicalAbsolutePath() async throws {
        let shell = Shell()
        // `bash` lives at `/bin/bash`, not `/usr/bin/bash`. The
        // wrong path must NOT shadow the registered command.
        #expect(shell.commandForCatalogPath("/usr/bin/bash") == nil)
    }

    @Test func rejectsBareName() async throws {
        let shell = Shell()
        #expect(shell.commandForCatalogPath("bash") == nil)
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
