import Foundation
import Testing
@testable import swift_bash
import BashInterpreter

/// Verifies the FS layout that `swift-bash exec --sandbox` wires up.
///
/// The legacy ``SandboxedOverlayFileSystem`` model captured every
/// write — workspace AND `/tmp` — in an in-memory layer, so SwiftPorts
/// CLIs (`gzip`, `gunzip`, `fd`, …) couldn't see them through
/// `Data(contentsOf:)`. The CLI now uses a ``MountedFileSystem`` that
/// puts both mounts on real disk, with the temp dir backed by
/// `NSTemporaryDirectory()` so the sandbox works on every host the
/// rest of the toolkit builds for. Issues #48 / #49 / #58.
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

        let fileSystem = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        try await fileSystem.writeData(
            Data("hello\n".utf8), to: "/batch/foo.txt", append: false)

        // File lives on real disk under the host workspace, NOT in an
        // in-memory layer — Foundation can open it directly.
        let hostFile = host.appendingPathComponent("foo.txt")
        let bytes = try Data(contentsOf: hostFile)
        #expect(String(bytes: bytes, encoding: .utf8) == "hello\n")
    }

    @Test func tmpWritesPersistToRealTempDir() async throws {
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        // Stamp a unique subdir under the host's real temp dir so we
        // don't clash with other runs / leak past the test.
        let probeName = "swift-bash-tmptest-\(UUID().uuidString)"
        let realTemp = NSTemporaryDirectory()
        let hostProbe = URL(fileURLWithPath: realTemp)
            .appendingPathComponent(probeName)
        defer { try? FileManager.default.removeItem(at: hostProbe) }

        let fileSystem = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        try await fileSystem.createDirectory("/tmp/\(probeName)",
                                             intermediates: true)
        try await fileSystem.writeData(
            Data("scratch\n".utf8),
            to: "/tmp/\(probeName)/data.txt", append: false)

        // Bash wrote through virtual `/tmp/...`; the mount table sends
        // that to the host's real temp dir. FileManager-backed callers
        // reading the real path see the same file (#58 — same agreement
        // property as #48 / #55, now portable).
        let hostFile = hostProbe.appendingPathComponent("data.txt")
        let bytes = try Data(contentsOf: hostFile)
        #expect(String(bytes: bytes, encoding: .utf8) == "scratch\n")
    }

    @Test func pathsOutsideMountsAreMissing() async throws {
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        let fileSystem = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
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

        let fileSystem = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        let bytes = try await fileSystem.readData("/batch/seed.txt")
        #expect(String(bytes: bytes, encoding: .utf8) == "preseed\n")
    }
}
