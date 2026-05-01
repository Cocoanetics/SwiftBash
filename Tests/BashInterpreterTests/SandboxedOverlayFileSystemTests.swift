import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct SandboxedOverlayFileSystemTests {

    // MARK: Test helpers

    private static func makeTempDir() -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("sbx-\(UUID())")
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func makeFs(
        root: String,
        mountPoint: String = "/batch",
        readOnly: Bool = false,
        allowSymlinks: Bool = false,
        includeTmpScratch: Bool = true,
        maxFileReadSize: Int64 = 10 * 1024 * 1024
    ) throws -> SandboxedOverlayFileSystem {
        try SandboxedOverlayFileSystem(.init(
            root: root,
            mountPoint: mountPoint,
            readOnly: readOnly,
            maxFileReadSize: maxFileReadSize,
            allowSymlinks: allowSymlinks,
            includeTmpScratch: includeTmpScratch))
    }

    // MARK: Construction

    @Test func rejectsMissingRoot() throws {
        #expect(throws: FileSystemError.self) {
            _ = try SandboxedOverlayFileSystem(.init(
                root: "/definitely/not/here/\(UUID())"))
        }
    }

    @Test func rejectsRootMount() throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        #expect(throws: FileSystemError.self) {
            _ = try makeFs(root: root, mountPoint: "/")
        }
    }

    @Test func seedsMountPointAndTmp() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root)

        #expect(try await fs.metadata("/")?.kind == .directory)
        #expect(try await fs.metadata("/batch")?.kind == .directory)
        #expect(try await fs.metadata("/tmp")?.kind == .directory)
    }

    @Test func tmpScratchOptional() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root, includeTmpScratch: false)
        #expect(try await fs.metadata("/tmp") == nil)
    }

    // MARK: Read fall-through to host

    @Test func readsHostFileThroughMount() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        try "hello".write(toFile: root + "/a.txt",
                          atomically: true, encoding: .utf8)
        let fs = try makeFs(root: root)
        let data = try await fs.readData("/batch/a.txt")
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test func listsHostDirectoryThroughMount() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        try "a".write(toFile: root + "/a.txt",
                      atomically: true, encoding: .utf8)
        try "b".write(toFile: root + "/b.txt",
                      atomically: true, encoding: .utf8)
        let fs = try makeFs(root: root)
        let names = try await fs.list("/batch")
        #expect(Set(names) == ["a.txt", "b.txt"])
    }

    @Test func metadataSizeFromHost() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        try "12345".write(toFile: root + "/n.txt",
                          atomically: true, encoding: .utf8)
        let fs = try makeFs(root: root)
        #expect(try await fs.metadata("/batch/n.txt")?.size == 5)
    }

    // MARK: Write isolation

    @Test func writesNeverPersistToHost() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root)

        try await fs.writeData(Data("vapor".utf8),
                               to: "/batch/x.txt", append: false)
        #expect(try await fs.readData("/batch/x.txt")
                == Data("vapor".utf8))
        // Host filesystem must not have seen this write.
        #expect(!FileManager.default.fileExists(atPath: root + "/x.txt"))
    }

    @Test func overlayMasksHostFile() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        try "host".write(toFile: root + "/c.txt",
                         atomically: true, encoding: .utf8)
        let fs = try makeFs(root: root)
        try await fs.writeData(Data("memory".utf8),
                               to: "/batch/c.txt", append: false)
        #expect(try await fs.readData("/batch/c.txt")
                == Data("memory".utf8))
        // Host file unchanged.
        #expect(try String(contentsOfFile: root + "/c.txt", encoding: .utf8)
                == "host")
    }

    @Test func appendStartsFromHostContent() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        try "one\n".write(toFile: root + "/log",
                          atomically: true, encoding: .utf8)
        let fs = try makeFs(root: root)
        try await fs.writeData(Data("two\n".utf8),
                               to: "/batch/log", append: true)
        let combined = try await fs.readData("/batch/log")
        #expect(String(decoding: combined, as: UTF8.self)
                == "one\ntwo\n")
        // Host file still single-line.
        #expect(try String(contentsOfFile: root + "/log", encoding: .utf8)
                == "one\n")
    }

    @Test func removeAddsTombstoneForHostFile() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        try "x".write(toFile: root + "/g.txt",
                      atomically: true, encoding: .utf8)
        let fs = try makeFs(root: root)
        try await fs.remove("/batch/g.txt", recursive: false)
        #expect(try await fs.metadata("/batch/g.txt") == nil)
        // List no longer surfaces it.
        let names = try await fs.list("/batch")
        #expect(names.contains("g.txt") == false)
        // Host file untouched.
        #expect(FileManager.default.fileExists(atPath: root + "/g.txt"))
    }

    @Test func readOnlyRejectsWrites() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root, readOnly: true)
        let err = await #expect(throws: FileSystemError.self) {
            try await fs.writeData(Data("x".utf8),
                                   to: "/batch/x", append: false)
        }
        if case .permissionDenied = err { } else {
            Issue.record("expected permissionDenied, got \(String(describing: err))")
        }
    }

    // MARK: Sandbox confinement

    @Test func pathsOutsideMountReportMissing() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root)
        #expect(try await fs.metadata("/etc") == nil)
        #expect(try await fs.metadata("/Users") == nil)
        #expect(try await fs.metadata("/private") == nil)
    }

    @Test func dotDotEscapeIsRejected() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        try "secret".write(toFile: root + "/in.txt",
                           atomically: true, encoding: .utf8)
        let fs = try makeFs(root: root)
        // /batch/../etc lexically normalizes to /etc — outside the mount.
        #expect(try await fs.metadata("/batch/../etc") == nil)
        // Attempts to escape via deeper traversal also fail.
        await #expect(throws: FileSystemError.self) {
            _ = try await fs.readData("/batch/../etc/passwd")
        }
    }

    @Test func writeOutsideMountRejected() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root)
        await #expect(throws: FileSystemError.self) {
            try await fs.writeData(Data("x".utf8),
                                   to: "/etc/passwd", append: false)
        }
    }

    // MARK: Symlink guard

    @Test func symlinkOnHostReportsMissing() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
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

        let fs = try makeFs(root: root)
        // Following the symlink would expose the file outside the
        // sandbox; it must look missing instead.
        #expect(try await fs.metadata("/batch/link") == nil)
        await #expect(throws: FileSystemError.self) {
            _ = try await fs.readData("/batch/link")
        }
    }

    @Test func escapeSymlinkHiddenFromListing() async throws {
        // Listing must agree with reachability: if `metadata("/batch/X")`
        // returns nil because X is a symlink pointing outside the
        // sandbox, then `list("/batch")` must not include "X" either.
        // Otherwise scripts could enumerate host filenames via `ls`
        // even though they can't read them.
        let root = Self.makeTempDir(); defer { cleanup(root) }
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

        let fs = try makeFs(root: root)
        let entries = try await fs.list("/batch")
        #expect(entries.contains("keep.txt"),
                "regular files must still be listed")
        #expect(!entries.contains("escape-link"),
                "escape symlink leaked into listing: \(entries)")
    }

    @Test func brokenSymlinkHiddenFromListing() async throws {
        // A dangling symlink (`/batch/dangling -> /nonexistent`) is
        // unreachable in every other API; it must not show up in
        // `ls` either.
        let root = Self.makeTempDir(); defer { cleanup(root) }
        try FileManager.default.createSymbolicLink(
            atPath: root + "/dangling",
            withDestinationPath: "/tmp/does-not-exist-\(UUID())")
        try "real".write(toFile: root + "/visible",
                         atomically: true, encoding: .utf8)

        let fs = try makeFs(root: root)
        let entries = try await fs.list("/batch")
        #expect(entries.contains("visible"))
        #expect(!entries.contains("dangling"),
                "dangling symlink leaked into listing: \(entries)")
    }

    @Test func brokenSymlinkLeafLooksMissingAndWriteStaysInOverlay() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        // Symlink to a non-existent file *outside* root. We must not
        // expose the symlink as a stat'able entry, and a write through
        // the same virtual path must land in the in-memory overlay
        // rather than creating a file outside the sandbox.
        let danglingTarget = "/tmp/does-not-exist-\(UUID())"
        try FileManager.default.createSymbolicLink(
            atPath: root + "/dangling",
            withDestinationPath: danglingTarget)

        let fs = try makeFs(root: root)
        #expect(try await fs.metadata("/batch/dangling") == nil)

        try await fs.writeData(Data("contained".utf8),
                               to: "/batch/dangling", append: false)
        // Read sees the in-memory overwrite, not the symlink.
        #expect(try await fs.readData("/batch/dangling")
                == Data("contained".utf8))
        // The dangling target outside the sandbox was NOT created.
        #expect(!FileManager.default.fileExists(atPath: danglingTarget))
    }

    @Test func symlinkOpRejectedWhenDisabled() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root)
        let err = await #expect(throws: FileSystemError.self) {
            try await fs.symlink(target: "/etc",
                                 at: "/batch/leak")
        }
        if case .permissionDenied = err { } else {
            Issue.record("expected permissionDenied, got \(String(describing: err))")
        }
    }

    @Test func symlinksAllowedInMemoryWhenEnabled() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root, allowSymlinks: true)
        try await fs.writeData(Data("hi".utf8),
                               to: "/batch/target", append: false)
        try await fs.symlink(target: "/batch/target",
                             at: "/batch/link")
        let meta = try await fs.metadata("/batch/link")
        #expect(meta?.kind == .symlink)
        #expect(meta?.symlinkTarget == "/batch/target")
    }

    // MARK: /tmp scratch

    @Test func tmpScratchAcceptsWritesIndependentOfHost() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root)
        try await fs.writeData(Data("scratch".utf8),
                               to: "/tmp/note", append: false)
        #expect(try await fs.readData("/tmp/note")
                == Data("scratch".utf8))
        // Real /tmp must be untouched by this write.
        #expect(!FileManager.default.fileExists(atPath: "/tmp/note")
                || (try? String(contentsOfFile: "/tmp/note", encoding: .utf8))
                    != "scratch")
    }

    @Test func makeTempPathLandsInTmpScratch() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root)
        let p = try await fs.makeTempPath(prefix: "swiftbash")
        #expect(p.hasPrefix("/tmp/swiftbash-"))
    }

    // MARK: Error sanitization

    @Test func errorMessageReferencesVirtualPathOnly() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root)
        do {
            _ = try await fs.readData("/batch/never.txt")
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
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root, readOnly: true)
        do {
            try await fs.writeData(Data(),
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
        let root = Self.makeTempDir(); defer { cleanup(root) }
        try "x".write(toFile: root + "/p.txt",
                      atomically: true, encoding: .utf8)
        let fs = try makeFs(root: root)
        try await fs.chmod("/batch/p.txt", mode: 0o600)
        #expect(try await fs.metadata("/batch/p.txt")?.mode == 0o600)
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
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = try makeFs(root: root)
        // Normalises while staying inside the mount.
        #expect(try await fs.canonicalize("/batch/./",
                                          allowMissing: true) == "/batch")
        // Outside the mount → notFound (when not allowed missing).
        await #expect(throws: FileSystemError.self) {
            _ = try await fs.canonicalize("/etc", allowMissing: false)
        }
    }

    @Test func maxFileReadSizeRejectsLargeFile() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        // Write a 1 KiB file but cap reads at 100 bytes.
        let big = String(repeating: "x", count: 1024)
        try big.write(toFile: root + "/big.txt",
                      atomically: true, encoding: .utf8)
        let fs = try makeFs(root: root, maxFileReadSize: 100)
        await #expect(throws: FileSystemError.self) {
            _ = try await fs.readData("/batch/big.txt")
        }
    }
}
