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
/// puts both mounts on real disk, with virtual `/tmp` backed by a
/// per-instance `swiftbash-<UUID>` dir under `NSTemporaryDirectory()`
/// so the sandbox works on every host AND concurrent instances can't
/// see each other's scratch. Issues #48 / #49 / #58 / #82.
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

        let (fileSystem, tempHost) = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        defer { try? FileManager.default.removeItem(at: tempHost) }
        try await fileSystem.writeData(
            Data("hello\n".utf8), to: "/batch/foo.txt", append: false)

        // File lives on real disk under the host workspace, NOT in an
        // in-memory layer — Foundation can open it directly.
        let hostFile = host.appendingPathComponent("foo.txt")
        let bytes = try Data(contentsOf: hostFile)
        #expect(String(bytes: bytes, encoding: .utf8) == "hello\n")
    }

    @Test func tmpWritesPersistToPerInstanceTempDir() async throws {
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        let (fileSystem, tempHost) = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        defer { try? FileManager.default.removeItem(at: tempHost) }
        try await fileSystem.createDirectory("/tmp/probe",
                                             intermediates: true)
        try await fileSystem.writeData(
            Data("scratch\n".utf8),
            to: "/tmp/probe/data.txt", append: false)

        // Bash wrote through virtual `/tmp/...`; the mount table sends
        // that to this instance's own temp dir — NOT the shared
        // platform temp root (#82). FileManager-backed callers reading
        // the instance dir's real path see the same file (#48 / #58).
        let hostFile = tempHost.appendingPathComponent("probe")
            .appendingPathComponent("data.txt")
        let bytes = try Data(contentsOf: hostFile)
        #expect(String(bytes: bytes, encoding: .utf8) == "scratch\n")
        let rootProbe = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe")
        #expect(!FileManager.default.fileExists(atPath: rootProbe.path))
    }

    @Test func tmpIsIsolatedPerInstance() async throws {
        // Two sandboxes in the same process must not share /tmp: a
        // hardcoded name like `/tmp/secret.txt` resolves into each
        // instance's own backing dir (#82).
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        let (fsA, tempA) = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        defer { try? FileManager.default.removeItem(at: tempA) }
        let (fsB, tempB) = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        defer { try? FileManager.default.removeItem(at: tempB) }
        #expect(tempA.path != tempB.path)

        try await fsA.writeData(
            Data("A's secret\n".utf8), to: "/tmp/secret.txt", append: false)
        // B sees no such file — not A's content, not a collision.
        #expect(try await fsB.metadata("/tmp/secret.txt") == nil)
        try await fsB.writeData(
            Data("B's notes\n".utf8), to: "/tmp/secret.txt", append: false)
        let backA = try await fsA.readData("/tmp/secret.txt")
        #expect(String(bytes: backA, encoding: .utf8) == "A's secret\n")
    }

    @Test func bothFacadesReachTheSameTmpFiles() async throws {
        // `$TMPDIR` carries the virtual `/tmp` spelling now (#83):
        // bash translates it through the mount table (Facade A), and
        // FileManager-backed callers translate the SAME spelling
        // through `Shell.resolve` + the sandbox's path mapping
        // (Facade B). Both must land on this instance's own temp dir
        // — the pre-#83 identity mount (host path mounted at itself)
        // is gone, so the host spelling no longer routes through the
        // mount table at all.
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        let (fileSystem, tempHost) = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        defer { try? FileManager.default.removeItem(at: tempHost) }

        try await fileSystem.writeData(
            Data("agree\n".utf8), to: "/tmp/agree.txt", append: false)

        // Facade B: resolve the virtual spelling on a shell carrying
        // the same mapping, authorize it, and read with Foundation.
        let shell = Shell(fileSystem: fileSystem)
        shell.sandbox = .confined(to: fileSystem.mapping,
                                  home: "/batch",
                                  temporaryDirectory: tempHost)
        let resolved = shell.resolve("/tmp/agree.txt")
        #expect(resolved.path
                == tempHost.appendingPathComponent("agree.txt").path)
        try await shell.sandbox?.authorize(resolved)
        let viaFoundation = try Data(contentsOf: resolved)
        #expect(String(bytes: viaFoundation, encoding: .utf8) == "agree\n")

        // The identity mount is retired: the mount table is just
        // workspace + /tmp, and the host spelling doesn't resolve
        // through the bash-side FS any more.
        #expect(fileSystem.mountList.map(\.virtual).sorted()
                == ["/batch", "/tmp"])
        #expect(try await fileSystem.metadata(tempHost.path) == nil)
    }

    @Test func pathsOutsideMountsAreMissing() async throws {
        let host = try Self.makeScratchDir()
        defer { try? FileManager.default.removeItem(at: host) }

        let (fileSystem, tempHost) = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        defer { try? FileManager.default.removeItem(at: tempHost) }
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

        let (fileSystem, tempHost) = try ExecCommand.makeSandboxFileSystem(
            sandboxRoot: host.path, workspace: "/batch")
        defer { try? FileManager.default.removeItem(at: tempHost) }
        let bytes = try await fileSystem.readData("/batch/seed.txt")
        #expect(String(bytes: bytes, encoding: .utf8) == "preseed\n")
    }
}
