import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct RealpathCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(RealpathCommand.self)
        return cap
    }

    @Test func resolvesExistingAbsolutePath() async throws {
        let cap = makeShell()
        try await cap.shell.run("realpath /tmp")
        let out = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // On macOS /tmp is a symlink to /private/tmp — we resolve symlinks.
        #expect(out == "/tmp" || out == "/private/tmp", "got `\(out)`")
    }

    @Test func normalisesDotDot() async throws {
        // Use a non-symlinked path so we don't need to care about
        // macOS's /tmp → /private/tmp symlink.
        let cap = makeShell()
        try await cap.shell.run("realpath /usr/bin/..")
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/usr")
    }

    @Test func missingPathFailsByDefault() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("realpath /definitely/not/a/real/path")
        #expect(!status.isSuccess)
        #expect(cap.stderr.contains("No such file"), "\(cap.stderr)")
    }

    @Test func missingFlagAllowsNonexistentPath() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("realpath -m /definitely/not/a/real/path")
        #expect(status == .success)
        #expect(cap.stdout == "/definitely/not/a/real/path\n")
    }

    @Test func relativePathUsesShellCwd() async throws {
        let cap = makeShell()
        cap.shell.environment.workingDirectory = "/tmp"
        try await cap.shell.run("realpath -m sub/file.txt")
        let out = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out.hasSuffix("/tmp/sub/file.txt")
                || out.hasSuffix("/private/tmp/sub/file.txt"),
                "got `\(out)`")
    }

    @Test func tildeUsesHome() async throws {
        let cap = makeShell()
        cap.shell.environment["HOME"] = "/Users/foo"
        try await cap.shell.run("realpath -m ~/docs")
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "/Users/foo/docs")
    }
}
