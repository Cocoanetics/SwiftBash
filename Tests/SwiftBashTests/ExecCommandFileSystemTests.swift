import Foundation
import Testing
@testable import swift_bash
import BashInterpreter

/// Verifies the FS layout that `swift-bash exec --sandbox` wires up.
///
/// The legacy ``SandboxedOverlayFileSystem`` model captured every
/// write — workspace AND `/tmp` — in an in-memory layer, so SwiftPorts
/// CLIs (`gzip`, `gunzip`, `fd`, …) couldn't see them through
/// `Data(contentsOf:)`. The CLI now uses a ``MountedFileSystem``
/// that puts both mounts on real disk, so tools that resolve a virtual
/// path to a host URL actually find the file. Issues #48 / #49.
@Suite(.timeLimit(.minutes(1))) struct ExecCommandFileSystemTests {

    /// Each test gets its own scratch dir under `NSTemporaryDirectory()`
    /// to act as the host workspace. `defer`-cleaned in every test.
    private static func makeScratchDir() throws -> URL {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-bash-fstest-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    @Test func workspaceWritesPersistToHost() async throws {
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        let fileSystem = ExecCommand.makeFileSystem(
            workspace: "/batch", sandboxRoot: host.path)
        try await fileSystem.writeData(
            Data("hello\n".utf8), to: "/batch/foo.txt", append: false)

        // File lives on real disk under the host workspace, NOT in an
        // in-memory layer — Foundation can open it directly.
        let hostFile = host.appendingPathComponent("foo.txt")
        let bytes = try Data(contentsOf: hostFile)
        #expect(String(bytes: bytes, encoding: .utf8) == "hello\n")
    }

    @Test func tmpWritesPersistToRealTmp() async throws {
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        // Stamp a unique subdir under /tmp so we don't clash with other
        // runs / leak past the test.
        let probeName = "swift-bash-tmptest-\(UUID().uuidString)"
        let hostProbe = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent(probeName)
        defer { try? FileManager.default.removeItem(at: hostProbe) }

        let fileSystem = ExecCommand.makeFileSystem(
            workspace: "/batch", sandboxRoot: host.path)
        try await fileSystem.createDirectory("/tmp/\(probeName)",
                                             intermediates: true)
        try await fileSystem.writeData(
            Data("scratch\n".utf8),
            to: "/tmp/\(probeName)/data.txt", append: false)

        // SwiftPorts CLIs use `Data(contentsOf:)` with virtual URLs.
        // On macOS realpath resolves /tmp -> /private/tmp, so a
        // file URL spelled `/tmp/.../data.txt` reaches the same inode
        // we just wrote.
        let virtualURL = URL(fileURLWithPath:
            "/tmp/\(probeName)/data.txt")
        let bytes = try Data(contentsOf: virtualURL)
        #expect(String(bytes: bytes, encoding: .utf8) == "scratch\n")
    }

    @Test func pathsOutsideMountsAreMissing() async throws {
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        let fileSystem = ExecCommand.makeFileSystem(
            workspace: "/batch", sandboxRoot: host.path)
        // `/etc` and `/Users` exist on the host but aren't mounted.
        // The FS reports `nil` metadata (not a thrown error) so bash
        // tests like `[ -f /etc/passwd ]` behave as on a chroot.
        #expect(try await fileSystem.metadata("/etc/passwd") == nil)
        #expect(try await fileSystem.metadata("/Users") == nil)
    }

    @Test func workspaceMountIsRespected() async throws {
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        // Seed a file directly on the host to confirm the workspace
        // mount surfaces it under the virtual path.
        let seed = host.appendingPathComponent("seed.txt")
        try Data("preseed\n".utf8).write(to: seed)

        let fileSystem = ExecCommand.makeFileSystem(
            workspace: "/batch", sandboxRoot: host.path)
        let bytes = try await fileSystem.readData("/batch/seed.txt")
        #expect(String(bytes: bytes, encoding: .utf8) == "preseed\n")
    }
}
