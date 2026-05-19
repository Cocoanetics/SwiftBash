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

    @Test func temporaryDirectoryIsVirtualTmp() {
        // `Shell.temporaryDirectory` reads `sandbox.temporaryDirectory`.
        // Bash sets `TMPDIR=/tmp`; the sandbox must agree so SwiftJSCore's
        // `os.tmpdir()` and similar consumers return the same virtual
        // path the bash environment exposes.
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        #expect(sandbox.temporaryDirectory.path == "/tmp")
    }
}
