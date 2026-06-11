import Testing
import Foundation
import ShellKit
@testable import BashInterpreter

/// Coverage for `Sandbox.bashWorkspace(workspace:temporaryDirectory:)` —
/// the URL gate the SwiftBash `--sandbox` CLI pairs with the real-disk
/// ``MountedFileSystem`` mounting the workspace and a per-instance temp
/// dir. The gate accepts the virtual workspace mount point and the temp
/// dir in its host spelling (what `$TMPDIR` carries); it does NOT accept
/// the virtual `/tmp` spelling — callers of this gate do real I/O on the
/// path as given, so literal `/tmp` would reach the host's shared temp
/// dir, not this sandbox's. Regression cover for #48 / #55 / #58 / #82.
@Suite(.timeLimit(.minutes(1))) struct BashWorkspaceSandboxTests {

    /// Create (on disk) a per-instance temp dir shaped like the CLI's
    /// `swiftbash-<UUID>`. Caller removes it.
    private static func makeInstanceTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(),
                      isDirectory: true)
            .appendingPathComponent("swiftbash-gatetest-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func authorizesWorkspaceRoot() async throws {
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        try await sandbox.authorize(
            URL(fileURLWithPath: "/batch/file.txt"))
        try await sandbox.authorize(
            URL(fileURLWithPath: "/batch/nested/dir/file"))
    }

    @Test func authorizesInstanceTempDir() async throws {
        // The CLI passes its per-instance temp dir; the carve-out
        // accepts the dir and anything under it, so `$TMPDIR`-spelled
        // paths from SwiftPorts CLIs / SwiftScript authorize the same
        // files the bash side writes through the mount (#48 / #82).
        let tempDir = try Self.makeInstanceTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sandbox = ShellKit.Sandbox.bashWorkspace(
            workspace: "/batch", temporaryDirectory: tempDir)
        try await sandbox.authorize(tempDir)
        try await sandbox.authorize(
            tempDir.appendingPathComponent("retest_fd_repro"))
        try await sandbox.authorize(
            tempDir.appendingPathComponent("retest_fd_repro")
                .appendingPathComponent("data.txt"))
    }

    @Test func deniesVirtualTmpSpelling() async throws {
        // Virtual `/tmp` is bash's spelling, translated by the mount
        // table. Callers of this gate carry no virtual→host translation
        // (that lands with #83) — a literal `/tmp/...` would do real
        // I/O on the host's shared `/tmp`, not this sandbox's temp dir,
        // so the gate denies it (#82).
        let tempDir = try Self.makeInstanceTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sandbox = ShellKit.Sandbox.bashWorkspace(
            workspace: "/batch", temporaryDirectory: tempDir)
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: "/tmp"))
        }
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(fileURLWithPath: "/tmp/retest_fd_repro"))
        }
    }

    @Test func deniesSiblingInstanceTempDir() async throws {
        // Two concurrent sandboxes get sibling `swiftbash-<UUID>` dirs
        // under the same platform temp root. Instance A's gate must not
        // authorize instance B's dir — nor the shared root itself (#82).
        let mine = try Self.makeInstanceTempDir()
        let sibling = try Self.makeInstanceTempDir()
        defer {
            try? FileManager.default.removeItem(at: mine)
            try? FileManager.default.removeItem(at: sibling)
        }
        let sandbox = ShellKit.Sandbox.bashWorkspace(
            workspace: "/batch", temporaryDirectory: mine)
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                sibling.appendingPathComponent("leak.txt"))
        }
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(fileURLWithPath: NSTemporaryDirectory(),
                    isDirectory: true))
        }
    }

    @Test func defaultGateAcceptsPlatformTempRoot() async throws {
        // Without an explicit `temporaryDirectory:` the gate falls back
        // to the platform temp root — shared with the whole process,
        // but what bare API callers had before #82. The CLI always
        // passes a per-instance dir instead.
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
        // The classic prefix-collision bug: a path that merely starts
        // with an accepted prefix's characters (no `/` boundary) must
        // not pass. Cover both the temp dir and the workspace.
        let tempDir = try Self.makeInstanceTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sandbox = ShellKit.Sandbox.bashWorkspace(
            workspace: "/batch", temporaryDirectory: tempDir)
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(fileURLWithPath: tempDir.path + "extra"))
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
        // Regression coverage for the #55 review concern: a bash-side
        // `ln -s / "$TMPDIR/p"` plants a real symlink inside the temp
        // dir whose *unresolved* path the carve-out would otherwise
        // happily authorize — letting FileManager-backed bridges follow
        // the link out of the sandbox. Aim the link at `/` so it
        // resolves on every platform — `/etc/passwd` doesn't exist on
        // the Android emulator and dangling-link resolution behaves
        // differently across the libc backends.
        let tempDir = try Self.makeInstanceTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let host = tempDir.appendingPathComponent("escape-link").path
        try FileManager.default.createSymbolicLink(
            atPath: host, withDestinationPath: "/")

        let sandbox = ShellKit.Sandbox.bashWorkspace(
            workspace: "/batch", temporaryDirectory: tempDir)
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: host))
        }
    }
#endif

    @Test func allowsLegitimateTmpFilesAfterSymlinkResolution() async throws {
        // The canonical re-check must not regress the legitimate case
        // where a real file exists under the temp dir (which on macOS
        // symlink-resolves through `/private/var/folders/…` — both
        // spellings stay authorized).
        let tempDir = try Self.makeInstanceTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("legit.txt").path
        FileManager.default.createFile(atPath: path, contents: Data("hi".utf8))

        let sandbox = ShellKit.Sandbox.bashWorkspace(
            workspace: "/batch", temporaryDirectory: tempDir)
        try await sandbox.authorize(URL(fileURLWithPath: path))
    }

    @Test func temporaryDirectoryIsRealTempPath() {
        // `Shell.temporaryDirectory` reads `sandbox.temporaryDirectory`.
        // Without an explicit override the gate reports the platform
        // temp root; the CLI overrides with its per-instance dir so
        // SwiftJSCore's `os.tmpdir()` and similar consumers return the
        // same path `$TMPDIR` carries.
        let sandbox = ShellKit.Sandbox.bashWorkspace(workspace: "/batch")
        let expected = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).standardizedFileURL.path
        let actual = sandbox.temporaryDirectory.standardizedFileURL.path
        #expect(actual == expected)
    }

    @Test func temporaryDirectoryOverrideIsReported() async throws {
        // An embedder (e.g. iBash, isolating /tmp per document) passes
        // its own temp dir; the gate reports it, and a file URL under it
        // is still authorized by the carve-out.
        let custom = URL(fileURLWithPath: NSTemporaryDirectory(),
                         isDirectory: true)
            .appendingPathComponent("custom-\(UUID().uuidString)",
                                    isDirectory: true)
        let sandbox = ShellKit.Sandbox.bashWorkspace(
            workspace: "/batch", temporaryDirectory: custom)
        #expect(sandbox.temporaryDirectory.standardizedFileURL.path
                == custom.standardizedFileURL.path)
        try await sandbox.authorize(custom.appendingPathComponent("f"))
    }

    @Test func authorizeNetworkRoutesNonFileURLs() async throws {
        let recorder = URLRecorder()
        let tempDir = try Self.makeInstanceTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sandbox = ShellKit.Sandbox.bashWorkspace(
            workspace: "/batch", temporaryDirectory: tempDir) { url in
            await recorder.record(url)
        }
        // Non-file URL → the embedder's closure handles it.
        try await sandbox.authorize(URL(string: "https://api.example.com/x")!)
        #expect(await recorder.hosts == ["api.example.com"])
        // File URLs keep using the workspace + temp carve-out, never the
        // network closure.
        try await sandbox.authorize(URL(fileURLWithPath: "/batch/f"))
        try await sandbox.authorize(tempDir.appendingPathComponent("f"))
        #expect(await recorder.hosts.count == 1)
    }

    @Test func authorizeNetworkCanDeny() async throws {
        struct Blocked: Error {}
        let tempDir = try Self.makeInstanceTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sandbox = ShellKit.Sandbox.bashWorkspace(
            workspace: "/batch", temporaryDirectory: tempDir) { _ in
            throw Blocked()
        }
        await #expect(throws: Blocked.self) {
            try await sandbox.authorize(
                URL(string: "https://blocked.example/")!)
        }
        // …a temp-dir file URL is still allowed (carve-out unaffected).
        try await sandbox.authorize(tempDir.appendingPathComponent("ok"))
    }
}

private actor URLRecorder {
    private(set) var hosts: [String] = []
    func record(_ url: URL) { hosts.append(url.host ?? "") }
}
