import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct SandboxedOverlayFileSystemTests {

    // MARK: Construction

    @Test func rejectsMissingRoot() throws {
        #expect(throws: FileSystemError.self) {
            _ = try SandboxedOverlayFileSystem(.init(
                root: "/definitely/not/here/\(UUID())"))
        }
    }

    @Test func rejectsRootMount() throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        #expect(throws: FileSystemError.self) {
            _ = try SandboxedOverlayTestHelpers.makeFs(root: root, mountPoint: "/")
        }
    }

    @Test func seedsMountPointAndTmp() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)

        #expect(try await fileSystem.metadata("/")?.kind == .directory)
        #expect(try await fileSystem.metadata("/batch")?.kind == .directory)
        #expect(try await fileSystem.metadata("/tmp")?.kind == .directory)
    }

    @Test func tmpScratchOptional() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root, includeTmpScratch: false)
        #expect(try await fileSystem.metadata("/tmp") == nil)
    }

    // MARK: Read fall-through to host

    @Test func readsHostFileThroughMount() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        try "hello".write(toFile: root + "/a.txt",
                          atomically: true, encoding: .utf8)
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        let data = try await fileSystem.readData("/batch/a.txt")
        #expect(String(bytes: data, encoding: .utf8) == "hello")
    }

    @Test func listsHostDirectoryThroughMount() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        try "a".write(toFile: root + "/a.txt",
                      atomically: true, encoding: .utf8)
        try "b".write(toFile: root + "/b.txt",
                      atomically: true, encoding: .utf8)
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        let names = try await fileSystem.list("/batch")
        #expect(Set(names.map(\.name)) == ["a.txt", "b.txt"])
    }

    @Test func metadataSizeFromHost() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        try "12345".write(toFile: root + "/n.txt",
                          atomically: true, encoding: .utf8)
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        #expect(try await fileSystem.metadata("/batch/n.txt")?.size == 5)
    }

    // MARK: Write isolation

    @Test func writesNeverPersistToHost() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)

        try await fileSystem.writeData(Data("vapor".utf8),
                               to: "/batch/x.txt", append: false)
        #expect(try await fileSystem.readData("/batch/x.txt")
                == Data("vapor".utf8))
        // Host filesystem must not have seen this write.
        #expect(!FileManager.default.fileExists(atPath: root + "/x.txt"))
    }

    @Test func overlayMasksHostFile() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        try "host".write(toFile: root + "/c.txt",
                         atomically: true, encoding: .utf8)
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        try await fileSystem.writeData(Data("memory".utf8),
                               to: "/batch/c.txt", append: false)
        #expect(try await fileSystem.readData("/batch/c.txt")
                == Data("memory".utf8))
        // Host file unchanged.
        #expect(try String(contentsOfFile: root + "/c.txt", encoding: .utf8)
                == "host")
    }

    @Test func appendStartsFromHostContent() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        try "one\n".write(toFile: root + "/log",
                          atomically: true, encoding: .utf8)
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        try await fileSystem.writeData(Data("two\n".utf8),
                               to: "/batch/log", append: true)
        let combined = try await fileSystem.readData("/batch/log")
        #expect(String(bytes: combined, encoding: .utf8)
                == "one\ntwo\n")
        // Host file still single-line.
        #expect(try String(contentsOfFile: root + "/log", encoding: .utf8)
                == "one\n")
    }

    @Test func removeAddsTombstoneForHostFile() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
        try "x".write(toFile: root + "/g.txt",
                      atomically: true, encoding: .utf8)
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        try await fileSystem.remove("/batch/g.txt", recursive: false)
        #expect(try await fileSystem.metadata("/batch/g.txt") == nil)
        // List no longer surfaces it.
        let names = try await fileSystem.list("/batch")
        #expect(names.contains(where: { $0.name == "g.txt" }) == false)
        // Host file untouched.
        #expect(FileManager.default.fileExists(atPath: root + "/g.txt"))
    }

    @Test func readOnlyRejectsWrites() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root, readOnly: true)
        let err = await #expect(throws: FileSystemError.self) {
            try await fileSystem.writeData(Data("x".utf8),
                                   to: "/batch/x", append: false)
        }
        if case .permissionDenied = err { } else {
            Issue.record("expected permissionDenied, got \(String(describing: err))")
        }
    }

    // MARK: /tmp scratch

    @Test func tmpScratchAcceptsWritesIndependentOfHost() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        try await fileSystem.writeData(Data("scratch".utf8),
                               to: "/tmp/note", append: false)
        #expect(try await fileSystem.readData("/tmp/note")
                == Data("scratch".utf8))
        // Real /tmp must be untouched by this write.
        #expect(!FileManager.default.fileExists(atPath: "/tmp/note")
                || (try? String(contentsOfFile: "/tmp/note", encoding: .utf8))
                    != "scratch")
    }

    @Test func makeTempPathLandsInTmpScratch() async throws {
        let root = try SandboxedOverlayTestHelpers.makeTempDir(); defer { SandboxedOverlayTestHelpers.cleanup(root) }
         let fileSystem = try SandboxedOverlayTestHelpers.makeFs(root: root)
        let path = try await fileSystem.makeTempPath(prefix: "swiftbash")
        #expect(path.hasPrefix("/tmp/swiftbash-"))
    }
}
