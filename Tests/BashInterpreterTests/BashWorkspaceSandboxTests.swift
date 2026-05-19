import Testing
import Foundation
import ShellKit
@testable import BashInterpreter

/// Coverage for `Sandbox.bashWorkspace(workspace:)` — the URL gate the
/// SwiftBash `--sandbox` CLI pairs with the real-disk
/// ``MountedFileSystem`` mounting the workspace and `/tmp`. The gate
/// accepts the virtual workspace mount point plus `/tmp`, so
/// SwiftPorts CLIs and the SwiftScript interpreter authorize the same
/// paths the bash side writes to. Regression coverage for #48 / #55.
@Suite(.timeLimit(.minutes(1))) struct BashWorkspaceSandboxTests {

    @Test func authorizesWorkspaceRoot() async throws {
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        try await sandbox.authorize(
            URL(fileURLWithPath: "/batch/file.txt"))
        try await sandbox.authorize(
            URL(fileURLWithPath: "/batch/nested/dir/file"))
    }

    @Test func authorizesTmpScratchRoot() async throws {
        // The bash sandbox mounts host `/tmp` at virtual `/tmp` and a
        // script's `cd /tmp; fd X` lands at virtual `/tmp` — without
        // the carve-out, every SwiftPorts CLI invocation from there
        // tripped "file URL is outside sandbox root" (#48).
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        try await sandbox.authorize(URL(fileURLWithPath: "/tmp"))
        try await sandbox.authorize(
            URL(fileURLWithPath: "/tmp/retest_fd_repro"))
        try await sandbox.authorize(
            URL(fileURLWithPath: "/tmp/retest_fd_repro/data.txt"))
    }

    @Test func deniesPathsOutsideBothRoots() async throws {
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(fileURLWithPath: "/etc/passwd"))
        }
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(fileURLWithPath: "/Users/someone/Documents"))
        }
    }

    @Test func deniesPrefixSiblings() async throws {
        // The classic prefix-collision bug: `/tmpfile` (no trailing
        // slash) must not be treated as inside `/tmp`. Same for
        // workspace prefix overlap.
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(fileURLWithPath: "/tmpfile"))
        }
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(fileURLWithPath: "/batchwork/foo"))
        }
    }

    @Test func deniesNonFileURLs() async throws {
        // Non-file URLs go through the host allowlist (empty here).
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(string: "https://example.com/")!)
        }
    }

    // Host `/tmp` doesn't exist on Windows, and the `--sandbox` mode
    // these tests cover isn't a Windows target anyway — the bash
    // sandbox mounts `/tmp` to the host's real `/tmp`. Both checks
    // need to plant real on-disk symlinks / files under `/tmp` to
    // exercise the URL gate's canonical re-check, so they're gated
    // to Unix-y hosts.
#if !os(Windows)
    @Test func deniesTmpSymlinkEscape() async throws {
        // Regression coverage for the #55 review concern: once host
        // `/tmp` is mounted at virtual `/tmp`, a bash-side
        // `ln -s /etc/passwd /tmp/p` plants a real symlink whose
        // *unresolved* path (`/tmp/p`) the carve-out would otherwise
        // happily authorize — letting FileManager-backed bridges
        // follow the link out of the sandbox. The URL gate has to
        // reject these the same way `MountedFileSystem.canonicalGate`
        // does on the bash side.
        let link = "/tmp/swiftbash-escape-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: "/etc/passwd")
        defer { try? FileManager.default.removeItem(atPath: link) }

        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: link))
        }
    }

    @Test func allowsLegitimateTmpFilesAfterSymlinkResolution() async throws {
        // The new canonical re-check must not regress the legitimate
        // case where a real file exists under host `/tmp` (which on
        // macOS resolves to `/private/tmp` — both spellings stay
        // authorized).
        let path = "/tmp/swiftbash-legit-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: path, contents: Data("hi".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        try await sandbox.authorize(URL(fileURLWithPath: path))
    }
#endif

    @Test func temporaryDirectoryIsVirtualTmp() {
        // `Shell.temporaryDirectory` reads `sandbox.temporaryDirectory`.
        // Bash sets `TMPDIR=/tmp`; the sandbox must agree so SwiftJSCore's
        // `os.tmpdir()` and similar consumers return the same virtual
        // path the bash environment exposes.
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        #expect(sandbox.temporaryDirectory.path == "/tmp")
    }
}
