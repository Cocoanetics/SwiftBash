import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct RealFileSystemTests {

    /// Fresh temp directory per test, automatically cleaned up.
    private static func makeTempDir() throws -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("fs-test-\(UUID())")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: metadata

    @Test func metadataForFile() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("a.txt")
        try "hello".write(toFile: filePath, atomically: true, encoding: .utf8)

        let fileSystem = RealFileSystem()
        let meta = try await fileSystem.metadata(filePath)
        #expect(meta?.kind == .file)
        #expect(meta?.size == 5)
    }

    @Test func metadataForDirectory() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let fileSystem = RealFileSystem()
        let meta = try await fileSystem.metadata(root)
        #expect(meta?.kind == .directory)
    }

    @Test func metadataNilForMissing() async throws {
        let fileSystem = RealFileSystem()
        let meta = try await fileSystem.metadata("/definitely/not/here/\(UUID())")
        #expect(meta == nil)
    }

    #if !os(Windows)
    @Test func metadataFollowsSymlink() async throws {
        // /tmp is a symlink to /private/tmp on macOS — follows to a dir.
        // Linux's /tmp is a real directory; Android lays out userland
        // tmp at /data/local/tmp instead. Either way `metadata` should
        // see a directory.
        #if os(Android)
        let path = "/data/local/tmp"
        #else
        let path = "/tmp"
        #endif
        let fileSystem = RealFileSystem()
        let meta = try await fileSystem.metadata(path)
        #expect(meta?.kind == .directory)
    }
    #endif

    // MARK: list

    @Test func listReturnsEntries() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        for name in ["a", "b", "c"] {
            _ = FileManager.default.createFile(
                atPath: (root as NSString).appendingPathComponent(name),
                contents: nil)
        }
        let fileSystem = RealFileSystem()
        let entries = try await fileSystem.list(root)
        #expect(Set(entries.map(\.name)) == ["a", "b", "c"])
    }

    @Test func listMissingThrowsNotFound() async throws {
        let fileSystem = RealFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fileSystem.list("/definitely/not/here/\(UUID())")
        }
    }

    // MARK: read / write

    @Test func writeThenRead() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("hi.txt")
        let fileSystem = RealFileSystem()

        try await fileSystem.writeData(Data("hello\n".utf8), to: filePath, append: false)
        let read = try await fileSystem.readData(filePath)
        #expect(String(bytes: read, encoding: .utf8) == "hello\n")
    }

    @Test func appendAddsAtEnd() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("log.txt")
        let fileSystem = RealFileSystem()

        try await fileSystem.writeData(Data("one\n".utf8), to: filePath, append: false)
        try await fileSystem.writeData(Data("two\n".utf8), to: filePath, append: true)

        let read = try await fileSystem.readData(filePath)
        #expect(String(bytes: read, encoding: .utf8) == "one\ntwo\n")
    }

    @Test func appendCreatesIfMissing() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("new.txt")
        let fileSystem = RealFileSystem()

        try await fileSystem.writeData(Data("created\n".utf8), to: filePath, append: true)
        let read = try await fileSystem.readData(filePath)
        #expect(String(bytes: read, encoding: .utf8) == "created\n")
    }

    @Test func readMissingThrows() async throws {
        let fileSystem = RealFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fileSystem.readData("/definitely/not/here/\(UUID())")
        }
    }

    // MARK: streaming read

    @Test func openReadStreamsChunks() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("big.bin")
        // 128 KB of zeros so we exercise at least two chunks.
        let payload = Data(repeating: 0x41, count: 128 * 1024)
        try payload.write(to: URL(fileURLWithPath: filePath))

        let fileSystem = RealFileSystem()
        let source = try await fileSystem.openRead(filePath)
        var accumulated = Data()
        for await chunk in source.bytes { accumulated.append(chunk) }
        #expect(accumulated == payload)
    }

    // MARK: touch

    @Test func touchCreatesEmptyFile() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("new.txt")
        let fileSystem = RealFileSystem()

        try await fileSystem.touch(filePath)
        let meta = try await fileSystem.metadata(filePath)
        #expect(meta?.kind == .file)
        #expect(meta?.size == 0)
    }

    @Test func touchUpdatesMtime() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("existing.txt")
        try "content".write(toFile: filePath, atomically: true, encoding: .utf8)

        // Roll mtime back to the epoch so we can prove touch updates it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: filePath)

        let fileSystem = RealFileSystem()
        try await fileSystem.touch(filePath)
        let meta = try await fileSystem.metadata(filePath)
        #expect(meta!.modifiedAt.timeIntervalSince1970 > 1_000_000_000)
    }

    // MARK: createDirectory

    @Test func createDirectory() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("sub")
        let fileSystem = RealFileSystem()

        try await fileSystem.createDirectory(filePath, intermediates: false)
        let meta = try await fileSystem.metadata(filePath)
        #expect(meta?.kind == .directory)
    }

    @Test func createDirectoryRequiresParentsForNestedPath() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("a/b/c")
        let fileSystem = RealFileSystem()

        await #expect(throws: FileSystemError.self) {
            try await fileSystem.createDirectory(filePath, intermediates: false)
        }
        try await fileSystem.createDirectory(filePath, intermediates: true)
        let meta = try await fileSystem.metadata(filePath)
        #expect(meta?.kind == .directory)
    }

    @Test func createDirectoryAlreadyExistsThrows() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let fileSystem = RealFileSystem()
        let err = await #expect(throws: FileSystemError.self) {
            try await fileSystem.createDirectory(root, intermediates: false)
        }
        if case .alreadyExists = err { } else {
            Issue.record("expected .alreadyExists, got \(String(describing: err))")
        }
    }

    // MARK: remove

    @Test func removeFile() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let filePath = (root as NSString).appendingPathComponent("gone.txt")
        _ = FileManager.default.createFile(atPath: filePath, contents: Data())

        let fileSystem = RealFileSystem()
        try await fileSystem.remove(filePath, recursive: false)
        let meta = try await fileSystem.metadata(filePath)
        #expect(meta == nil)
    }

    @Test func removeDirectoryNeedsRecursive() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let sub = (root as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            atPath: sub, withIntermediateDirectories: false)
        _ = FileManager.default.createFile(
            atPath: (sub as NSString).appendingPathComponent("file"),
            contents: Data())

        let fileSystem = RealFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fileSystem.remove(sub, recursive: false)
        }
        try await fileSystem.remove(sub, recursive: true)
        let meta = try await fileSystem.metadata(sub)
        #expect(meta == nil)
    }

    @Test func removeEmptyDirectoryNonRecursively() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let sub = (root as NSString).appendingPathComponent("empty")
        try FileManager.default.createDirectory(
            atPath: sub, withIntermediateDirectories: false)

        let fileSystem = RealFileSystem()
        try await fileSystem.remove(sub, recursive: false)
        #expect(try await fileSystem.metadata(sub) == nil)
    }

    // MARK: move / copy

    @Test func moveRenames() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let src = (root as NSString).appendingPathComponent("a.txt")
        let dst = (root as NSString).appendingPathComponent("b.txt")
        try "payload".write(toFile: src, atomically: true, encoding: .utf8)

        let fileSystem = RealFileSystem()
        try await fileSystem.move(from: src, to: dst)
        #expect(try await fileSystem.metadata(src) == nil)
        #expect(try await fileSystem.metadata(dst)?.kind == .file)
        // swiftlint:disable:next optional_data_string_conversion - test reads file written above
        #expect(String(decoding: try await fileSystem.readData(dst), as: UTF8.self)
                == "payload")
    }

    @Test func copyFile() async throws {
        let root = try Self.makeTempDir(); defer { cleanup(root) }
        let src = (root as NSString).appendingPathComponent("src.txt")
        let dst = (root as NSString).appendingPathComponent("dst.txt")
        try "data".write(toFile: src, atomically: true, encoding: .utf8)

        let fileSystem = RealFileSystem()
        try await fileSystem.copy(from: src, to: dst)
        #expect(try await fileSystem.metadata(src)?.kind == .file)
        #expect(try await fileSystem.metadata(dst)?.kind == .file)
        // swiftlint:disable:next optional_data_string_conversion - test reads file written above
        #expect(String(decoding: try await fileSystem.readData(dst), as: UTF8.self)
                == "data")
    }

    // MARK: canonicalize

    #if !os(Windows)
    @Test func canonicalizeResolvesDotDot() async throws {
        // The assertion is about `..` collapsing. Pick a non-symlinked
        // ancestor that exists on each platform: macOS/Linux have
        // /usr/bin, Android has /system/bin (its read-only system
        // partition). Neither path is a symlink so the resolved value
        // is the parent literally.
        #if os(Android)
        let input = "/system/bin/.."
        let expected = "/system"
        #else
        let input = "/usr/bin/.."
        let expected = "/usr"
        #endif
        let fileSystem = RealFileSystem()
        let resolved = try await fileSystem.canonicalize(input, allowMissing: false)
        #expect(resolved == expected)
    }
    #endif

    @Test func canonicalizeMissingThrowsUnlessAllowed() async throws {
        let fileSystem = RealFileSystem()
        let fake = "/nope/\(UUID())"
        await #expect(throws: FileSystemError.self) {
            try await fileSystem.canonicalize(fake, allowMissing: false)
        }
        let resolved = try await fileSystem.canonicalize(fake, allowMissing: true)
        #expect(resolved == fake)
    }
}
