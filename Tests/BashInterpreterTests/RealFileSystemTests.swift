import Testing
import Foundation
@testable import BashInterpreter

@Suite struct RealFileSystemTests {

    /// Fresh temp directory per test, automatically cleaned up.
    private static func makeTempDir() -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("fs-test-\(UUID())")
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: metadata

    @Test func metadataForFile() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("a.txt")
        try "hello".write(toFile: p, atomically: true, encoding: .utf8)

        let fs = RealFileSystem()
        let meta = try await fs.metadata(p)
        #expect(meta?.kind == .file)
        #expect(meta?.size == 5)
    }

    @Test func metadataForDirectory() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = RealFileSystem()
        let meta = try await fs.metadata(root)
        #expect(meta?.kind == .directory)
    }

    @Test func metadataNilForMissing() async throws {
        let fs = RealFileSystem()
        let meta = try await fs.metadata("/definitely/not/here/\(UUID())")
        #expect(meta == nil)
    }

    @Test func metadataFollowsSymlink() async throws {
        // /tmp is a symlink to /private/tmp on macOS — follows to a dir.
        let fs = RealFileSystem()
        let meta = try await fs.metadata("/tmp")
        #expect(meta?.kind == .directory)
    }

    // MARK: list

    @Test func listReturnsEntries() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        for name in ["a", "b", "c"] {
            FileManager.default.createFile(
                atPath: (root as NSString).appendingPathComponent(name),
                contents: nil)
        }
        let fs = RealFileSystem()
        let entries = try await fs.list(root)
        #expect(Set(entries) == ["a", "b", "c"])
    }

    @Test func listMissingThrowsNotFound() async throws {
        let fs = RealFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fs.list("/definitely/not/here/\(UUID())")
        }
    }

    // MARK: read / write

    @Test func writeThenRead() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("hi.txt")
        let fs = RealFileSystem()

        try await fs.writeData(Data("hello\n".utf8), to: p, append: false)
        let read = try await fs.readData(p)
        #expect(String(decoding: read, as: UTF8.self) == "hello\n")
    }

    @Test func appendAddsAtEnd() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("log.txt")
        let fs = RealFileSystem()

        try await fs.writeData(Data("one\n".utf8), to: p, append: false)
        try await fs.writeData(Data("two\n".utf8), to: p, append: true)

        let read = try await fs.readData(p)
        #expect(String(decoding: read, as: UTF8.self) == "one\ntwo\n")
    }

    @Test func appendCreatesIfMissing() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("new.txt")
        let fs = RealFileSystem()

        try await fs.writeData(Data("created\n".utf8), to: p, append: true)
        let read = try await fs.readData(p)
        #expect(String(decoding: read, as: UTF8.self) == "created\n")
    }

    @Test func readMissingThrows() async throws {
        let fs = RealFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fs.readData("/definitely/not/here/\(UUID())")
        }
    }

    // MARK: streaming read

    @Test func openReadStreamsChunks() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("big.bin")
        // 128 KB of zeros so we exercise at least two chunks.
        let payload = Data(repeating: 0x41, count: 128 * 1024)
        try payload.write(to: URL(fileURLWithPath: p))

        let fs = RealFileSystem()
        let source = try await fs.openRead(p)
        var accumulated = Data()
        for await chunk in source.bytes { accumulated.append(chunk) }
        #expect(accumulated == payload)
    }

    // MARK: touch

    @Test func touchCreatesEmptyFile() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("new.txt")
        let fs = RealFileSystem()

        try await fs.touch(p)
        let meta = try await fs.metadata(p)
        #expect(meta?.kind == .file)
        #expect(meta?.size == 0)
    }

    @Test func touchUpdatesMtime() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("existing.txt")
        try "content".write(toFile: p, atomically: true, encoding: .utf8)

        // Roll mtime back to the epoch so we can prove touch updates it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: p)

        let fs = RealFileSystem()
        try await fs.touch(p)
        let meta = try await fs.metadata(p)
        #expect(meta!.modifiedAt.timeIntervalSince1970 > 1_000_000_000)
    }

    // MARK: createDirectory

    @Test func createDirectory() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("sub")
        let fs = RealFileSystem()

        try await fs.createDirectory(p, intermediates: false)
        let meta = try await fs.metadata(p)
        #expect(meta?.kind == .directory)
    }

    @Test func createDirectoryRequiresParentsForNestedPath() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("a/b/c")
        let fs = RealFileSystem()

        await #expect(throws: FileSystemError.self) {
            try await fs.createDirectory(p, intermediates: false)
        }
        try await fs.createDirectory(p, intermediates: true)
        let meta = try await fs.metadata(p)
        #expect(meta?.kind == .directory)
    }

    @Test func createDirectoryAlreadyExistsThrows() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let fs = RealFileSystem()
        let err = await #expect(throws: FileSystemError.self) {
            try await fs.createDirectory(root, intermediates: false)
        }
        if case .alreadyExists = err { } else {
            Issue.record("expected .alreadyExists, got \(String(describing: err))")
        }
    }

    // MARK: remove

    @Test func removeFile() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let p = (root as NSString).appendingPathComponent("gone.txt")
        FileManager.default.createFile(atPath: p, contents: Data())

        let fs = RealFileSystem()
        try await fs.remove(p, recursive: false)
        let meta = try await fs.metadata(p)
        #expect(meta == nil)
    }

    @Test func removeDirectoryNeedsRecursive() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let sub = (root as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            atPath: sub, withIntermediateDirectories: false)
        FileManager.default.createFile(
            atPath: (sub as NSString).appendingPathComponent("file"),
            contents: Data())

        let fs = RealFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fs.remove(sub, recursive: false)
        }
        try await fs.remove(sub, recursive: true)
        let meta = try await fs.metadata(sub)
        #expect(meta == nil)
    }

    @Test func removeEmptyDirectoryNonRecursively() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let sub = (root as NSString).appendingPathComponent("empty")
        try FileManager.default.createDirectory(
            atPath: sub, withIntermediateDirectories: false)

        let fs = RealFileSystem()
        try await fs.remove(sub, recursive: false)
        #expect(try await fs.metadata(sub) == nil)
    }

    // MARK: move / copy

    @Test func moveRenames() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let a = (root as NSString).appendingPathComponent("a.txt")
        let b = (root as NSString).appendingPathComponent("b.txt")
        try "payload".write(toFile: a, atomically: true, encoding: .utf8)

        let fs = RealFileSystem()
        try await fs.move(from: a, to: b)
        #expect(try await fs.metadata(a) == nil)
        #expect(try await fs.metadata(b)?.kind == .file)
        #expect(String(decoding: try await fs.readData(b), as: UTF8.self)
                == "payload")
    }

    @Test func copyFile() async throws {
        let root = Self.makeTempDir(); defer { cleanup(root) }
        let a = (root as NSString).appendingPathComponent("src.txt")
        let b = (root as NSString).appendingPathComponent("dst.txt")
        try "data".write(toFile: a, atomically: true, encoding: .utf8)

        let fs = RealFileSystem()
        try await fs.copy(from: a, to: b)
        #expect(try await fs.metadata(a)?.kind == .file)
        #expect(try await fs.metadata(b)?.kind == .file)
        #expect(String(decoding: try await fs.readData(b), as: UTF8.self)
                == "data")
    }

    // MARK: canonicalize

    @Test func canonicalizeResolvesDotDot() async throws {
        let fs = RealFileSystem()
        let resolved = try await fs.canonicalize("/usr/bin/..", allowMissing: false)
        #expect(resolved == "/usr")
    }

    @Test func canonicalizeMissingThrowsUnlessAllowed() async throws {
        let fs = RealFileSystem()
        let fake = "/nope/\(UUID())"
        await #expect(throws: FileSystemError.self) {
            try await fs.canonicalize(fake, allowMissing: false)
        }
        let ok = try await fs.canonicalize(fake, allowMissing: true)
        #expect(ok == fake)
    }
}
