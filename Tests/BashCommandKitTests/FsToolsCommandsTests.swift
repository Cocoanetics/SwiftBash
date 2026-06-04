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

    // Ownership must come from the shell's virtual `HostInfo`, not the
    // real inode the temp file carries (which would leak the host's
    // uid/gid) — `stat` has to agree with `ls -l`. Use ids distinct
    // from both the real host and the old hardcoded "user"/"group".
    @Test func statOwnershipTracksVirtualIdentity() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try "x".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        var info = cap.shell.hostInfo
        info.uid = 4242; info.userName = "alice"
        info.gid = 99; info.groupName = "crew"
        cap.shell.hostInfo = info
        try await cap.shell.run("stat -c '%u %U %g %G' f")
        #expect(cap.stdout == "4242 alice 99 crew\n")
    }

    @Test func statDefaultSummaryUsesVirtualUidGid() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try "x".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        var info = cap.shell.hostInfo
        info.uid = 4242; info.gid = 99
        cap.shell.hostInfo = info
        try await cap.shell.run("stat f")
        #expect(cap.stdout.contains("Uid: ( 4242)"))
        #expect(cap.stdout.contains("Gid: (   99)"))
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
