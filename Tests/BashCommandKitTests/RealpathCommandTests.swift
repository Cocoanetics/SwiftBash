import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct RealpathCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(RealpathCommand.self)
        return cap
    }

    #if !os(Windows)
    @Test func resolvesExistingAbsolutePath() async throws {
        // macOS's /tmp is a symlink to /private/tmp — we resolve
        // symlinks. Linux's /tmp is a plain directory. Android has no
        // /tmp; userland tmp is /data/local/tmp.
        #if os(Android)
        let input = "/data/local/tmp"
        let acceptable: Set<String> = ["/data/local/tmp"]
        #else
        let input = "/tmp"
        let acceptable: Set<String> = ["/tmp", "/private/tmp"]
        #endif
        let cap = makeShell()
        try await cap.shell.run("realpath \(input)")
        let out = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(acceptable.contains(out), "got `\(out)`")
    }
    #endif

    #if !os(Windows)
    @Test func normalisesDotDot() async throws {
        // Use a non-symlinked path so we don't need to care about
        // macOS's /tmp → /private/tmp symlink. Android has no /usr,
        // but its read-only /system partition has /system/bin.
        #if os(Android)
        let input = "/system/bin/.."
        let expected = "/system"
        #else
        let input = "/usr/bin/.."
        let expected = "/usr"
        #endif
        let cap = makeShell()
        try await cap.shell.run("realpath \(input)")
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
    }
    #endif

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
