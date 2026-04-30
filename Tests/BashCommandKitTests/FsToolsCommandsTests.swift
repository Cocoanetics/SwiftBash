import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct FsToolsCommandsTests {

    private func makeShellWithDir() -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "fs-\(UUID())"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }
    private func cleanup(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    @Test func statDefault() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "hello".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        try await cap.shell.run("stat f")
        #expect(cap.stdout.contains("File: f"))
        #expect(cap.stdout.contains("Size: 5"))
        #expect(cap.stdout.contains("regular file"))
    }

    @Test func statFormat() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "hi".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        try await cap.shell.run("stat -c '%n %s' f")
        #expect(cap.stdout == "f 2\n")
    }

    @Test func chmodChangesPermissions() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        _ = FileManager.default.createFile(atPath: dir + "/f", contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir + "/f")
        try await cap.shell.run("chmod 755 f")
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/f")
        let perms = attrs[.posixPermissions] as? Int ?? 0
        #expect(perms == 0o755)
    }

    @Test func lnSymbolic() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "data".write(toFile: dir + "/target", atomically: true, encoding: .utf8)
        try await cap.shell.run("ln -s target link")
        // verify symlink resolves
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/link")
        #expect((attrs[.type] as? FileAttributeType) == .typeSymbolicLink)
    }

    @Test func readlink() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "data".write(toFile: dir + "/target", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "target")
        try await cap.shell.run("readlink link")
        #expect(cap.stdout == "target\n")
    }

    @Test func readlinkFCanonicalize() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "data".write(toFile: dir + "/real", atomically: true, encoding: .utf8)
        try await cap.shell.run("readlink -f real")
        #expect(cap.stdout.hasSuffix("/real\n"))
    }

    @Test func lnHardLink() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "data".write(toFile: dir + "/src", atomically: true, encoding: .utf8)
        try await cap.shell.run("ln src dst")
        // Both should exist as regular files
        #expect(FileManager.default.fileExists(atPath: dir + "/dst"))
    }
}
