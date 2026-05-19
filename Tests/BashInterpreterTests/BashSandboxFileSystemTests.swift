import Testing
import Foundation
@testable import BashInterpreter

/// Coverage for the real-disk `MountedFileSystem` shape the
/// `swift-bash exec --sandbox` CLI installs: workspace mount at the
/// configured virtual path (default `/batch`) and host `/tmp` mounted
/// at virtual `/tmp`. Replaces the in-memory `SandboxedOverlayFileSystem`
/// suite — see #55 for the rationale (FileManager-backed callers now
/// see the same writes the bash builtins land on real disk).
@Suite(.timeLimit(.minutes(1))) struct BashSandboxFileSystemTests {

    private static func makeTempDir() throws -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("sbx-\(UUID())")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func makeFs(
        workspaceRoot: String,
        workspace: String = "/batch",
        tmpHost: String? = nil
    ) -> MountedFileSystem {
        let tmpDir = tmpHost ?? NSTemporaryDirectory()
        return MountedFileSystem(
            mounts: [
                .init(virtual: workspace, host: workspaceRoot),
                .init(virtual: "/tmp", host: tmpDir)
            ],
            backing: RealFileSystem())
    }

    // MARK: Mount synthesis

    @Test func rootAndMountPointsLookLikeDirectories() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let fileSystem = Self.makeFs(workspaceRoot: root)
        #expect(try await fileSystem.metadata("/")?.kind == .directory)
        #expect(try await fileSystem.metadata("/batch")?.kind == .directory)
        #expect(try await fileSystem.metadata("/tmp")?.kind == .directory)
    }

    @Test func rootListingShowsMountPoints() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let fileSystem = Self.makeFs(workspaceRoot: root)
        let names = try await fileSystem.list("/").map(\.name)
        #expect(Set(names) == ["batch", "tmp"])
    }

    @Test func canonicalizeOfSyntheticRootStaysAtRoot() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let fileSystem = Self.makeFs(workspaceRoot: root)
        #expect(try await fileSystem.canonicalize(
            "/", allowMissing: false) == "/")
    }

    @Test func mkdirAtSynthesizedRootReportsExists() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let fileSystem = Self.makeFs(workspaceRoot: root)
        let err = await #expect(throws: FileSystemError.self) {
            try await fileSystem.createDirectory("/", intermediates: false)
        }
        if case .alreadyExists = err { } else {
            Issue.record("expected alreadyExists, got \(String(describing: err))")
        }
    }

    // MARK: Real-disk writes land on the host

    @Test func writesToWorkspaceMountReachRealDisk() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let fileSystem = Self.makeFs(workspaceRoot: root)
        try await fileSystem.writeData(Data("durable".utf8),
                                       to: "/batch/x.txt", append: false)
        // FileManager — bypassing the FS abstraction — sees the file.
        // That's the whole point of #55: SwiftPorts CLIs / SwiftScript
        // bridges that walk the host filesystem directly through
        // FileManager now agree with bash on what's reachable.
        let hostPath = (root as NSString).appendingPathComponent("x.txt")
        #expect(FileManager.default.fileExists(atPath: hostPath))
        let read = try await fileSystem.readData("/batch/x.txt")
        #expect(String(data: read, encoding: .utf8) == "durable")
    }

    @Test func writesToTmpMountReachHostTmp() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let tmp = try Self.makeTempDir(); defer { Self.cleanup(tmp) }
        let fileSystem = Self.makeFs(workspaceRoot: root, tmpHost: tmp)
        try await fileSystem.writeData(Data("scratch".utf8),
                                       to: "/tmp/note", append: false)
        let hostPath = (tmp as NSString).appendingPathComponent("note")
        #expect(FileManager.default.fileExists(atPath: hostPath))
        let read = try await fileSystem.readData("/tmp/note")
        #expect(String(data: read, encoding: .utf8) == "scratch")
    }

    // MARK: Confinement

    @Test func pathsOutsideMountsLookMissing() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let fileSystem = Self.makeFs(workspaceRoot: root)
        #expect(try await fileSystem.metadata("/etc") == nil)
        #expect(try await fileSystem.metadata("/Users") == nil)
    }

    @Test func dotDotEscapeIsRejected() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let fileSystem = Self.makeFs(workspaceRoot: root)
        // `/batch/../etc` normalises lexically to `/etc`, which falls
        // outside every mount.
        #expect(try await fileSystem.metadata("/batch/../etc") == nil)
        await #expect(throws: FileSystemError.self) {
            _ = try await fileSystem.readData("/batch/../etc/passwd")
        }
    }

    @Test func writeOutsideMountsRejected() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let fileSystem = Self.makeFs(workspaceRoot: root)
        await #expect(throws: FileSystemError.self) {
            try await fileSystem.writeData(Data("x".utf8),
                                           to: "/etc/passwd", append: false)
        }
    }

    // MARK: Symlink confinement

    @Test func symlinkInWorkspacePointingOutsideIsHidden() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let outside = NSTemporaryDirectory()
            + "outside-\(UUID().uuidString).txt"
        try "leaked".write(toFile: outside,
                           atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(
            atPath: root + "/link", withDestinationPath: outside)

        let fileSystem = Self.makeFs(workspaceRoot: root)
        // The link's canonical host target escapes the workspace
        // mount, so MountedFileSystem reports it missing — the host
        // file never reaches the script even though the link itself
        // lives inside the workspace dir.
        #expect(try await fileSystem.metadata("/batch/link") == nil)
        await #expect(throws: FileSystemError.self) {
            _ = try await fileSystem.readData("/batch/link")
        }
    }

    // MARK: makeTempPath

    @Test func makeTempPathLandsInTmpMount() async throws {
        let root = try Self.makeTempDir(); defer { Self.cleanup(root) }
        let tmp = try Self.makeTempDir(); defer { Self.cleanup(tmp) }
        let fileSystem = Self.makeFs(workspaceRoot: root, tmpHost: tmp)
        let path = try await fileSystem.makeTempPath(prefix: "swiftbash")
        #expect(path.hasPrefix("/tmp/swiftbash"))
    }
}
