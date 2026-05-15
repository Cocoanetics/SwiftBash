import Testing
import Foundation
@testable import BashInterpreter

/// Sandbox-confinement / symlink-guard / error-sanitisation /
/// chmod / canonicalize / max-read-size tests for
/// `SandboxedOverlayFileSystem`. Split out of
/// `SandboxedOverlayFileSystemTests` so neither suite trips the
/// `type_body_length` lint.
@Suite(.timeLimit(.minutes(1))) struct SandboxedOverlayFileSystemSecurityTests {

    // MARK: Sandbox confinement

    @Test func pathsOutsideMountReportMissing() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        #expect(try await fileSystem.metadata("/etc") == nil)
        #expect(try await fileSystem.metadata("/Users") == nil)
        #expect(try await fileSystem.metadata("/private") == nil)
    }

    @Test func dotDotEscapeIsRejected() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        try "secret".write(toFile: root + "/in.txt",
                           atomically: true, encoding: .utf8)
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        // /batch/../etc lexically normalizes to /etc — outside the mount.
        #expect(try await fileSystem.metadata("/batch/../etc") == nil)
        // Attempts to escape via deeper traversal also fail.
        await #expect(throws: FileSystemError.self) {
            _ = try await fileSystem.readData("/batch/../etc/passwd")
        }
    }

    @Test func writeOutsideMountRejected() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        await #expect(throws: FileSystemError.self) {
            try await fileSystem.writeData(Data("x".utf8),
                                   to: "/etc/passwd", append: false)
        }
    }

    // MARK: Symlink guard

    @Test func symlinkOnHostReportsMissing() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        // Create a file outside root and a symlink pointing at it
        // *inside* root. With symlinks disabled, the link must not
        // resolve (and must not even be visible as a dangling entry).
        let outside = NSTemporaryDirectory()
            + "outside-\(UUID().uuidString).txt"
        try "leaked".write(toFile: outside,
                           atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(
            atPath: root + "/link", withDestinationPath: outside)

         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        // Following the symlink would expose the file outside the
        // sandbox; it must look missing instead.
        #expect(try await fileSystem.metadata("/batch/link") == nil)
        await #expect(throws: FileSystemError.self) {
            _ = try await fileSystem.readData("/batch/link")
        }
    }

    @Test func escapeSymlinkHiddenFromListing() async throws {
        // Listing must agree with reachability: if `metadata("/batch/X")`
        // returns nil because X is a symlink pointing outside the
        // sandbox, then `list("/batch")` must not include "X" either.
        // Otherwise scripts could enumerate host filenames via `ls`
        // even though they can't read them.
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        let outside = NSTemporaryDirectory()
            + "outside-\(UUID().uuidString).txt"
        try "leaked".write(toFile: outside,
                           atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(
            atPath: root + "/escape-link",
            withDestinationPath: outside)
        // Plant a real file alongside, to make sure the escape filter
        // doesn't accidentally drop legitimate entries.
        try "ok".write(toFile: root + "/keep.txt",
                       atomically: true, encoding: .utf8)

         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        let entries = try await fileSystem.list("/batch").map(\.name)
        #expect(entries.contains("keep.txt"),
                "regular files must still be listed")
        #expect(!entries.contains("escape-link"),
                "escape symlink leaked into listing: \(entries)")
    }

    @Test func brokenSymlinkHiddenFromListing() async throws {
        // A dangling symlink (`/batch/dangling -> /nonexistent`) is
        // unreachable in every other API; it must not show up in
        // `ls` either.
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        try FileManager.default.createSymbolicLink(
            atPath: root + "/dangling",
            withDestinationPath: "/tmp/does-not-exist-\(UUID())")
        try "real".write(toFile: root + "/visible",
                         atomically: true, encoding: .utf8)

         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        let entries = try await fileSystem.list("/batch").map(\.name)
        #expect(entries.contains("visible"))
        #expect(!entries.contains("dangling"),
                "dangling symlink leaked into listing: \(entries)")
    }

    @Test func brokenSymlinkLeafLooksMissingAndWriteStaysInOverlay() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        // Symlink to a non-existent file *outside* root. We must not
        // expose the symlink as a stat'able entry, and a write through
        // the same virtual path must land in the in-memory overlay
        // rather than creating a file outside the sandbox.
        let danglingTarget = "/tmp/does-not-exist-\(UUID())"
        try FileManager.default.createSymbolicLink(
            atPath: root + "/dangling",
            withDestinationPath: danglingTarget)

         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        #expect(try await fileSystem.metadata("/batch/dangling") == nil)

        try await fileSystem.writeData(Data("contained".utf8),
                               to: "/batch/dangling", append: false)
        // Read sees the in-memory overwrite, not the symlink.
        #expect(try await fileSystem.readData("/batch/dangling")
                == Data("contained".utf8))
        // The dangling target outside the sandbox was NOT created.
        #expect(!FileManager.default.fileExists(atPath: danglingTarget))
    }

    @Test func symlinkOpRejectedWhenDisabled() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        let err = await #expect(throws: FileSystemError.self) {
            try await fileSystem.symlink(target: "/etc",
                                 at: "/batch/leak")
        }
        if case .permissionDenied = err { } else {
            Issue.record("expected permissionDenied, got \(String(describing: err))")
        }
    }

    @Test func symlinksAllowedInMemoryWhenEnabled() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root, allowSymlinks: true)
        try await fileSystem.writeData(Data("hi".utf8),
                               to: "/batch/target", append: false)
        try await fileSystem.symlink(target: "/batch/target",
                             at: "/batch/link")
        let meta = try await fileSystem.metadata("/batch/link")
        #expect(meta?.kind == .symlink)
        #expect(meta?.symlinkTarget == "/batch/target")
    }

    // MARK: Error sanitization

    @Test func errorMessageReferencesVirtualPathOnly() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        do {
            _ = try await fileSystem.readData("/batch/never.txt")
            Issue.record("expected throw")
        } catch let err as FileSystemError {
            // Description must mention the virtual path and must NOT
            // mention the host root path.
            let msg = err.description
            #expect(msg.contains("/batch/never.txt"))
            #expect(!msg.contains(root),
                    "error leaked host path: \(msg)")
        }
    }

    @Test func writeErrorMentionsVirtualPathOnly() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root, readOnly: true)
        do {
            try await fileSystem.writeData(Data(),
                                   to: "/batch/x", append: false)
            Issue.record("expected throw")
        } catch let err as FileSystemError {
            let msg = err.description
            #expect(msg.contains("/batch/x"))
            #expect(!msg.contains(root))
        }
    }

    // MARK: Misc

    #if !os(Windows)
    @Test func chmodPromotesHostFile() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        try "x".write(toFile: root + "/p.txt",
                      atomically: true, encoding: .utf8)
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        try await fileSystem.chmod("/batch/p.txt", mode: 0o600)
        #expect(try await fileSystem.metadata("/batch/p.txt")?.mode == 0o600)
        // And host file's permissions are NOT changed. (Windows
        // doesn't have POSIX permission bits; Foundation reports a
        // synthetic constant for every file there, so this overlay-
        // isolation check is meaningless on that platform.)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: root + "/p.txt")
        let hostMode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(hostMode != 0o600,
                "host file permissions were modified — overlay isolation broken")
    }
    #endif

    @Test func canonicalizeNormalizesAndConfines() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        // Normalises while staying inside the mount.
        #expect(try await fileSystem.canonicalize("/batch/./",
                                          allowMissing: true) == "/batch")
        // Outside the mount → notFound (when not allowed missing).
        await #expect(throws: FileSystemError.self) {
            _ = try await fileSystem.canonicalize("/etc", allowMissing: false)
        }
    }

    @Test func maxFileReadSizeRejectsLargeFile() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        // Write a 1 KiB file but cap reads at 100 bytes.
        let big = String(repeating: "x", count: 1024)
        try big.write(toFile: root + "/big.txt",
                      atomically: true, encoding: .utf8)
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root, maxFileReadSize: 100)
        await #expect(throws: FileSystemError.self) {
            _ = try await fileSystem.readData("/batch/big.txt")
        }
    }
}
