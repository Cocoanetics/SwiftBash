import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct OverlayFileSystemTests {

    // MARK: BinCatalogOverlay through OverlayFileSystem

    /// `ls /` should expose the synthesized `bin` and `usr` from
    /// the BinCatalog overlay alongside whatever the backing FS has.
    @Test func rootListingMergesOverlayAndBacking() async throws {
        let backing = InMemoryFileSystem()
        try await backing.touch("/README.txt")
        let fs = OverlayFileSystem(
            backing: backing,
            providers: [BinCatalogOverlay()])
        let shell = Shell(fileSystem: fs)
        let entries = try await shell.withCurrent {
            try await shell.fileSystem.list("/").map(\.name)
        }
        #expect(entries.contains("README.txt"))
        #expect(entries.contains("bin"))
        #expect(entries.contains("usr"))
    }

    @Test func usrListingShowsBinAndLocal() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        let entries = try await shell.withCurrent {
            try await shell.fileSystem.list("/usr").map(\.name).sorted()
        }
        #expect(entries == ["bin", "local"])
    }

    @Test func chmodOnOverlayPathIsPermissionDenied() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        await shell.withCurrent {
            await #expect(throws: FileSystemError.permissionDenied("/usr")) {
                try await shell.fileSystem.chmod("/usr", mode: 0o777)
            }
        }
    }

    @Test func writingInsideOverlayIsPermissionDenied() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        await shell.withCurrent {
            await #expect(throws: FileSystemError.permissionDenied("/usr/whatever")) {
                try await shell.fileSystem.createDirectory(
                    "/usr/whatever", intermediates: false)
            }
        }
    }

    // MARK: HostDirectoryOverlay

    /// A HostDirectoryOverlay mounted at `/examples` exposes a host
    /// directory tree read-only, and the overlay layer rejects every
    /// mutation against any path under that root.
    @Test func hostDirectoryOverlayExposesContents() async throws {
        let root = NSTemporaryDirectory() + "host-overlay-\(UUID()).d"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        try "echo hi\n".write(toFile: root + "/hello.sh",
                              atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: root + "/nested",
                               withIntermediateDirectories: true)
        try "inside\n".write(toFile: root + "/nested/inside.txt",
                              atomically: true, encoding: .utf8)

        let backing = InMemoryFileSystem()
        try await backing.touch("/README.txt")
        let fs = OverlayFileSystem(
            backing: backing,
            providers: [
                BinCatalogOverlay(),
                HostDirectoryOverlay(
                    virtualRoot: "/examples",
                    hostRoot: URL(fileURLWithPath: root)),
            ])

        let shell = Shell(fileSystem: fs)
        try await shell.withCurrent {
            // / listing has both backing + overlay providers' children.
            let rootEntries = try await shell.fileSystem.list("/").map(\.name)
            #expect(rootEntries.contains("README.txt"))
            #expect(rootEntries.contains("bin"))
            #expect(rootEntries.contains("usr"))
            #expect(rootEntries.contains("examples"))

            // /examples listing reflects host contents.
            let exEntries = try await shell.fileSystem
                .list("/examples").map(\.name).sorted()
            #expect(exEntries == ["hello.sh", "nested"])

            // Read through.
            let data = try await shell.fileSystem.readData("/examples/hello.sh")
            #expect(String(data: data, encoding: .utf8) == "echo hi\n")

            // Mutation rejected.
            await #expect(throws: FileSystemError.permissionDenied(
                "/examples/hello.sh"))
            {
                try await shell.fileSystem.writeData(
                    Data(), to: "/examples/hello.sh", append: false)
            }
            await #expect(throws: FileSystemError.permissionDenied(
                "/examples/hello.sh"))
            {
                try await shell.fileSystem.remove(
                    "/examples/hello.sh", recursive: false)
            }
        }
    }

    /// Copying out of an overlay into the backing FS works — `cp
    /// /examples/foo.sh ~/foo.sh` is the standard workflow for
    /// customising a sample file.
    @Test func copyFromOverlayIntoBackingSucceeds() async throws {
        let root = NSTemporaryDirectory() + "host-overlay-cp-\(UUID()).d"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        try "original".write(toFile: root + "/src.txt",
                             atomically: true, encoding: .utf8)
        let fs = OverlayFileSystem(
            backing: InMemoryFileSystem(),
            providers: [HostDirectoryOverlay(
                virtualRoot: "/examples",
                hostRoot: URL(fileURLWithPath: root))])
        let shell = Shell(fileSystem: fs)
        try await shell.withCurrent {
            try await shell.fileSystem.copy(
                from: "/examples/src.txt", to: "/dst.txt")
            let bytes = try await shell.fileSystem.readData("/dst.txt")
            #expect(String(data: bytes, encoding: .utf8) == "original")
        }
    }
}
