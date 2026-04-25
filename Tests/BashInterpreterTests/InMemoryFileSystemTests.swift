import Testing
import Foundation
@testable import BashInterpreter

@Suite struct InMemoryFileSystemTests {

    // MARK: Seed + read

    @Test func seedFromDictionary() async throws {
        let fs = InMemoryFileSystem(files: [
            "/a.txt": Data("hello".utf8),
            "/dir/nested/b.txt": Data("world".utf8),
        ])
        #expect(try await fs.readData("/a.txt")
                == Data("hello".utf8))
        #expect(try await fs.readData("/dir/nested/b.txt")
                == Data("world".utf8))
    }

    @Test func metadataForSeededFile() async throws {
        let fs = InMemoryFileSystem(files: ["/a": Data("abc".utf8)])
        let meta = try await fs.metadata("/a")
        #expect(meta?.kind == .file)
        #expect(meta?.size == 3)
    }

    @Test func metadataForDirectory() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory("/dir", intermediates: false)
        let meta = try await fs.metadata("/dir")
        #expect(meta?.kind == .directory)
    }

    @Test func metadataNilForMissing() async throws {
        let fs = InMemoryFileSystem()
        #expect(try await fs.metadata("/nope") == nil)
    }

    // MARK: write + append

    @Test func writeTruncatesAndAppendAdds() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeData(Data("a\n".utf8), to: "/log", append: false)
        try await fs.writeData(Data("b\n".utf8), to: "/log", append: true)
        try await fs.writeData(Data("c\n".utf8), to: "/log", append: true)
        #expect(String(decoding: try await fs.readData("/log"),
                       as: UTF8.self) == "a\nb\nc\n")
    }

    @Test func writeCreatesIntermediateFailsWithoutP() async throws {
        let fs = InMemoryFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fs.writeData(
                Data("x".utf8), to: "/nope/file", append: false)
        }
    }

    // MARK: list

    @Test func list() async throws {
        let fs = InMemoryFileSystem(files: [
            "/a": Data(), "/b": Data(), "/c": Data(),
        ])
        let entries = try await fs.list("/")
        #expect(Set(entries) == ["a", "b", "c"])
    }

    @Test func listOnFileThrowsNotADirectory() async throws {
        let fs = InMemoryFileSystem(files: ["/a": Data()])
        let err = await #expect(throws: FileSystemError.self) {
            try await fs.list("/a")
        }
        if case .notADirectory = err { } else {
            Issue.record("expected .notADirectory, got \(String(describing: err))")
        }
    }

    // MARK: mkdir

    @Test func createDirectoryIntermediates() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory("/a/b/c", intermediates: true)
        #expect(try await fs.metadata("/a/b/c")?.kind == .directory)
    }

    @Test func createDirectoryNestedFailsWithoutIntermediates() async throws {
        let fs = InMemoryFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fs.createDirectory("/a/b/c", intermediates: false)
        }
    }

    @Test func createDirectoryAlreadyExists() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory("/x", intermediates: false)
        let err = await #expect(throws: FileSystemError.self) {
            try await fs.createDirectory("/x", intermediates: false)
        }
        if case .alreadyExists = err { } else {
            Issue.record("expected .alreadyExists, got \(String(describing: err))")
        }
    }

    // MARK: remove

    @Test func removeFile() async throws {
        let fs = InMemoryFileSystem(files: ["/x": Data()])
        try await fs.remove("/x", recursive: false)
        #expect(try await fs.metadata("/x") == nil)
    }

    @Test func removeNonEmptyDirNeedsRecursive() async throws {
        let fs = InMemoryFileSystem(files: ["/d/a": Data()])
        await #expect(throws: FileSystemError.self) {
            try await fs.remove("/d", recursive: false)
        }
        try await fs.remove("/d", recursive: true)
        #expect(try await fs.metadata("/d") == nil)
    }

    @Test func removeEmptyDirOK() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory("/empty", intermediates: false)
        try await fs.remove("/empty", recursive: false)
        #expect(try await fs.metadata("/empty") == nil)
    }

    // MARK: move + copy

    @Test func moveRenames() async throws {
        let fs = InMemoryFileSystem(files: ["/a": Data("x".utf8)])
        try await fs.move(from: "/a", to: "/b")
        #expect(try await fs.metadata("/a") == nil)
        #expect(try await fs.readData("/b") == Data("x".utf8))
    }

    @Test func copyDirectoryIsDeep() async throws {
        let fs = InMemoryFileSystem(files: [
            "/src/one": Data("1".utf8),
            "/src/nested/two": Data("2".utf8),
        ])
        try await fs.copy(from: "/src", to: "/dst")
        #expect(try await fs.readData("/dst/one") == Data("1".utf8))
        #expect(try await fs.readData("/dst/nested/two") == Data("2".utf8))
        // Mutations on src don't bleed into dst (true deep copy).
        try await fs.writeData(Data("mut".utf8), to: "/src/one", append: false)
        #expect(try await fs.readData("/dst/one") == Data("1".utf8))
    }

    @Test func copyToExistingDestinationFails() async throws {
        let fs = InMemoryFileSystem(files: [
            "/a": Data("x".utf8),
            "/b": Data("y".utf8),
        ])
        let err = await #expect(throws: FileSystemError.self) {
            try await fs.copy(from: "/a", to: "/b")
        }
        if case .alreadyExists = err { } else {
            Issue.record("expected .alreadyExists, got \(String(describing: err))")
        }
    }

    // MARK: canonicalize

    @Test func canonicalizeCollapsesDotDot() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory("/a/b", intermediates: true)
        #expect(try await fs.canonicalize("/a/b/..", allowMissing: false)
                == "/a")
    }

    @Test func canonicalizeStripsDot() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory("/a", intermediates: true)
        #expect(try await fs.canonicalize("/./a/./", allowMissing: false)
                == "/a")
    }

    // MARK: touch

    @Test func touchCreatesFile() async throws {
        let fs = InMemoryFileSystem()
        try await fs.touch("/a")
        let meta = try await fs.metadata("/a")
        #expect(meta?.kind == .file)
        #expect(meta?.size == 0)
    }

    @Test func touchUpdatesMtime() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeData(Data("x".utf8), to: "/a", append: false)
        let beforeMeta = try await fs.metadata("/a")!
        try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        try await fs.touch("/a")
        let afterMeta = try await fs.metadata("/a")!
        #expect(afterMeta.modifiedAt > beforeMeta.modifiedAt)
    }

    // MARK: openWrite streaming

    @Test func openWriteStreamsAppend() async throws {
        let fs = InMemoryFileSystem()
        let sink = try await fs.openWrite("/log", append: false)
        sink.write(Data("a\n".utf8))
        sink.write(Data("b\n".utf8))
        sink.finish()
        // Give the stream time to propagate (but onWrite is synchronous).
        #expect(String(decoding: try await fs.readData("/log"),
                       as: UTF8.self) == "a\nb\n")
    }

    // MARK: path normalisation edge cases

    @Test func normalizePathKeepsRoot() {
        #expect(InMemoryFileSystem.normalizePath("/") == "/")
        #expect(InMemoryFileSystem.normalizePath("//a//b/") == "/a/b")
        #expect(InMemoryFileSystem.normalizePath("/a/./b/../c") == "/a/c")
    }
}
