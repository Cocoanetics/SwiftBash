import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct FsToolsCommandsTests {

    private func makeShellWithDir() throws -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "fs-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }
    private func cleanup(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    @Test func statDefault() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try "hello".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        try await cap.shell.run("stat f")
        #expect(cap.stdout.contains("File: f"))
        #expect(cap.stdout.contains("Size: 5"))
        #expect(cap.stdout.contains("regular file"))
    }

    @Test func statFormat() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try "hi".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        try await cap.shell.run("stat -c '%n %s' f")
        #expect(cap.stdout == "f 2\n")
    }

    // Real FS (no virtualizing mount): `%u`/`%g` are the file's ACTUAL
    // owner — per-file ownership is preserved. `%U`/`%G` render the
    // shell identity's names (there's no passwd map to resolve uids).
    @Test func statShowsRealOwnershipOnRealFS() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        let path = dir + "/f"
        try "x".write(toFile: path, atomically: true, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let fileUID = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0
        let fileGID = (attrs[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0
        var info = cap.shell.hostInfo
        info.userName = "alice"; info.groupName = "crew"
        cap.shell.hostInfo = info
        try await cap.shell.run("stat -c '%u %U %g %G' f")
        #expect(cap.stdout == "\(fileUID) alice \(fileGID) crew\n")
    }

    // A MountedFileSystem virtualizes ownership at the boundary, so a
    // sandboxed `stat` reports the shell identity's uid/gid, never the
    // host inode's — the leak #65 was about, fixed at the FS rather than
    // by `stat` ignoring metadata.
    @Test func statVirtualizesOwnershipOnMountedFS() async throws {
        let dir = NSTemporaryDirectory() + "statmnt-\(UUID())"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "x".write(toFile: dir + "/f", atomically: true, encoding: .utf8)

        func mountedShell() -> CapturingShell {
            let cap = CapturingShell()
            cap.shell.fileSystem = MountedFileSystem(
                mounts: [.init(virtual: "/", host: dir)],
                backing: RealFileSystem())
            cap.shell.registerStandardCommands()
            var info = cap.shell.hostInfo
            info.uid = 4242; info.gid = 99
            cap.shell.hostInfo = info
            return cap
        }

        let cap1 = mountedShell()
        try await cap1.shell.run("stat -c '%u %g' /f")
        #expect(cap1.stdout == "4242 99\n")

        let cap2 = mountedShell()
        try await cap2.shell.run("stat /f")
        #expect(cap2.stdout.contains("Uid: ( 4242)"))
        #expect(cap2.stdout.contains("Gid: (   99)"))
    }

    // Directory-entry metadata from `list(_:)` must be virtualized too —
    // `FileEntry` carries `FileMetadata`, so `ls -l` / `find` read
    // ownership from the listing without a follow-up `stat`. That path
    // has to report the shell identity, not the host inode's uid/gid.
    @Test func listVirtualizesEntryOwnershipOnMountedFS() async throws {
        let dir = NSTemporaryDirectory() + "listmnt-\(UUID())"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "x".write(toFile: dir + "/f", atomically: true, encoding: .utf8)

        let cap = CapturingShell()
        cap.shell.fileSystem = MountedFileSystem(
            mounts: [.init(virtual: "/", host: dir)],
            backing: RealFileSystem())
        var info = cap.shell.hostInfo
        info.uid = 4242; info.gid = 99
        cap.shell.hostInfo = info

        let entries = try await Shell.$bashCurrent.withValue(cap.shell) {
            try await cap.shell.fileSystem.list("/")
        }
        let entry = try #require(entries.first { $0.name == "f" })
        #expect(entry.metadata.uid == 4242)
        #expect(entry.metadata.gid == 99)
    }

    #if !os(Windows)
    @Test func chmodChangesPermissions() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        _ = FileManager.default.createFile(atPath: dir + "/f", contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir + "/f")
        try await cap.shell.run("chmod 755 f")
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/f")
        let perms = attrs[.posixPermissions] as? Int ?? 0
        #expect(perms == 0o755)
    }
    #endif

    #if !os(Windows)
    @Test func lnSymbolic() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try "data".write(toFile: dir + "/target", atomically: true, encoding: .utf8)
        try await cap.shell.run("ln -s target link")
        // verify symlink resolves
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/link")
        #expect((attrs[.type] as? FileAttributeType) == .typeSymbolicLink)
    }
    #endif

    #if !os(Windows)
    @Test func readlink() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try "data".write(toFile: dir + "/target", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "target")
        try await cap.shell.run("readlink link")
        #expect(cap.stdout == "target\n")
    }
    #endif

    @Test func readlinkFCanonicalize() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try "data".write(toFile: dir + "/real", atomically: true, encoding: .utf8)
        try await cap.shell.run("readlink -f real")
        #expect(cap.stdout.hasSuffix("/real\n"))
    }

    // Android emulator: link(2) on `/data/local/tmp` is rejected
    // by SELinux for the `shell` domain. Skip outright — the
    // `withKnownIssue { } when:` form ran the body and hung in CI.
    #if !os(Android)
    @Test func lnHardLink() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try "data".write(toFile: dir + "/src", atomically: true, encoding: .utf8)
        try await cap.shell.run("ln src dst")
        #expect(FileManager.default.fileExists(atPath: dir + "/dst"))
    }
    #endif
}
