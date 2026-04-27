import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

// xattrs require Apple's extended-attribute syscalls; on Linux,
// `<sys/xattr.h>` symbols aren't surfaced by Swift's default Glibc
// module, so RealFileSystem falls through to the protocol's xattr
// no-ops. Skip the matching tests there until we vendor the C shim.
#if canImport(Darwin)

@Suite struct XattrCommandTests {

    private func makeShellWithDir() -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "xattr-\(UUID())"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }
    private func cleanup(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    @Test func writeAndList() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "x".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        try await cap.shell.run("xattr -w user.tag hello f")
        try await cap.shell.run("xattr f")
        #expect(cap.stdout.contains("user.tag"))
    }

    @Test func writeAndPrint() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "x".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        try await cap.shell.run("xattr -w user.color blue f")
        try await cap.shell.run("xattr -p user.color f")
        #expect(cap.stdout == "blue\n")
    }

    @Test func deleteAttribute() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "x".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        try await cap.shell.run("xattr -w user.a 1 f")
        try await cap.shell.run("xattr -w user.b 2 f")
        try await cap.shell.run("xattr -d user.a f")
        try await cap.shell.run("xattr f")
        #expect(!cap.stdout.contains("user.a"))
        #expect(cap.stdout.contains("user.b"))
    }

    @Test func clearAll() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "x".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        try await cap.shell.run("xattr -w user.a 1 f")
        try await cap.shell.run("xattr -w user.b 2 f")
        try await cap.shell.run("xattr -c f")
        try await cap.shell.run("xattr f")
        // macOS auto-adds `com.apple.provenance` on filesystem writes;
        // we can't remove that, but our `user.*` attrs should be gone.
        #expect(!cap.stdout.contains("user.a"))
        #expect(!cap.stdout.contains("user.b"))
    }

    @Test func longFormatShowsValues() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "x".write(toFile: dir + "/f", atomically: true, encoding: .utf8)
        try await cap.shell.run("xattr -w user.tag hello f")
        try await cap.shell.run("xattr -l f")
        #expect(cap.stdout.contains("user.tag"))
        #expect(cap.stdout.contains("hello"))
    }
}

#endif
