import Testing
import Foundation
import ShellKit
@testable import BashInterpreter

/// Coverage for `Sandbox.bashWorkspace(workspace:)` — the URL gate the
/// SwiftBash `--sandbox` CLI pairs with the real-disk
/// ``MountedFileSystem`` mounting the workspace and the platform's
/// real temp dir. The gate accepts the virtual workspace mount point,
/// `/tmp`, and the host's real temp dir (`NSTemporaryDirectory()`), so
/// SwiftPorts CLIs and the SwiftScript interpreter authorize the same
/// paths the bash side writes to on every platform. Regression cover
/// for #48 / #55 / #58.
@Suite(.timeLimit(.minutes(1))) struct BashWorkspaceSandboxTests {

    @Test func authorizesWorkspaceRoot() async throws {
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        try await sandbox.authorize(
            URL(fileURLWithPath: "/batch/file.txt"))
        try await sandbox.authorize(
            URL(fileURLWithPath: "/batch/nested/dir/file"))
    }

    @Test func authorizesTmpScratchRoot() async throws {
        // The bash sandbox mounts the host's real temp dir at virtual
        // `/tmp`; a script's `cd /tmp; fd X` lands at virtual `/tmp` —
        // without the carve-out, every SwiftPorts CLI invocation from
        // there tripped "file URL is outside sandbox root" (#48).
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        try await sandbox.authorize(URL(fileURLWithPath: "/tmp"))
        try await sandbox.authorize(
            URL(fileURLWithPath: "/tmp/retest_fd_repro"))
        try await sandbox.authorize(
            URL(fileURLWithPath: "/tmp/retest_fd_repro/data.txt"))
    }

    @Test func authorizesRealTempPath() async throws {
        // Callers using `$TMPDIR` (set to `NSTemporaryDirectory()` by
        // the CLI) hand the gate the real host path, not `/tmp`. The
        // mount table also exposes that real path at its true location
        // so both spellings reach the same files; the gate must accept
        // both. Regression for #58.
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        let realTemp = NSTemporaryDirectory()
        try await sandbox.authorize(URL(fileURLWithPath: realTemp))
        try await sandbox.authorize(URL(fileURLWithPath:
            (realTemp as NSString).appendingPathComponent("probe.txt")))
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

    // The canonical re-check relies on `URL.resolvingSymlinksInPath()`
    // to follow the symlink and re-evaluate the destination. swift-
    // corelibs-foundation's Windows implementation doesn't traverse
    // NTFS symlinks the way the Darwin/Glibc backends do — a planted
    // symlink survives canonicalisation unchanged and the gate's
    // second-pass check can't fire. Production code still depends on
    // OS-level sandboxing on Windows (see Threat model in
    // `Docs/Sandboxing.md`).
#if !os(Windows)
    @Test func deniesTmpSymlinkEscape() async throws {
        // Regression coverage for the #55 review concern: once the
        // temp dir is mounted at virtual `/tmp`, a bash-side
        // `ln -s / /tmp/p` plants a real symlink whose *unresolved*
        // path the carve-out would otherwise happily authorize —
        // letting FileManager-backed bridges follow the link out of
        // the sandbox. Plant the fixture at the host's real temp dir
        // (always writable, even where `/tmp` isn't) and aim the link
        // at `/` so it resolves on every platform — `/etc/passwd`
        // doesn't exist on the Android emulator and dangling-link
        // resolution behaves differently across the libc backends.
        let host = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("swiftbash-escape-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            atPath: host, withDestinationPath: "/")
        defer { try? FileManager.default.removeItem(atPath: host) }

        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: host))
        }
    }
#endif

    @Test func allowsLegitimateTmpFilesAfterSymlinkResolution() async throws {
        // The canonical re-check must not regress the legitimate case
        // where a real file exists under the host's temp dir (which on
        // macOS may symlink-resolve through `/private/var/folders/…` —
        // both spellings stay authorized).
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("swiftbash-legit-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: path, contents: Data("hi".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        try await sandbox.authorize(URL(fileURLWithPath: path))
    }

    @Test func temporaryDirectoryIsRealTempPath() {
        // `Shell.temporaryDirectory` reads `sandbox.temporaryDirectory`.
        // The CLI sets `$TMPDIR = NSTemporaryDirectory()`; the gate has
        // to agree so SwiftJSCore's `os.tmpdir()` and similar consumers
        // return the same real path the bash environment exposes.
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        let expected = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).standardizedFileURL.path
        let actual = sandbox.temporaryDirectory.standardizedFileURL.path
        #expect(actual == expected)
    }
}
