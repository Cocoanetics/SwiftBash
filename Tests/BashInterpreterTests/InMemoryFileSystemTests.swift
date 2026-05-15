import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct InMemoryFileSystemTests {

    // MARK: Seed + read

    @Test func seedFromDictionary() async throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/a.txt": Data("hello".utf8),
            "/dir/nested/b.txt": Data("world".utf8)
        ])
        #expect(try await fileSystem.readData("/a.txt")
                == Data("hello".utf8))
        #expect(try await fileSystem.readData("/dir/nested/b.txt")
                == Data("world".utf8))
    }

    @Test func metadataForSeededFile() async throws {
        let fileSystem = InMemoryFileSystem(files: ["/a": Data("abc".utf8)])
        let meta = try await fileSystem.metadata("/a")
        #expect(meta?.kind == .file)
        #expect(meta?.size == 3)
    }

    @Test func metadataForDirectory() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.createDirectory("/dir", intermediates: false)
        let meta = try await fileSystem.metadata("/dir")
        #expect(meta?.kind == .directory)
    }

    @Test func metadataNilForMissing() async throws {
        let fileSystem = InMemoryFileSystem()
        #expect(try await fileSystem.metadata("/nope") == nil)
    }

    // MARK: write + append

    @Test func writeTruncatesAndAppendAdds() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.writeData(Data("a\n".utf8), to: "/log", append: false)
        try await fileSystem.writeData(Data("b\n".utf8), to: "/log", append: true)
        try await fileSystem.writeData(Data("c\n".utf8), to: "/log", append: true)
        let logData = try await fileSystem.readData("/log")
        #expect(String(bytes: logData, encoding: .utf8) == "a\nb\nc\n")
    }

    @Test func writeCreatesIntermediateFailsWithoutP() async throws {
        let fileSystem = InMemoryFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fileSystem.writeData(
                Data("x".utf8), to: "/nope/file", append: false)
        }
    }

    // MARK: list

    @Test func list() async throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/a": Data(), "/b": Data(), "/c": Data()
        ])
        let entries = try await fileSystem.list("/")
        #expect(Set(entries.map(\.name)) == ["a", "b", "c"])
    }

    @Test func listOnFileThrowsNotADirectory() async throws {
        let fileSystem = InMemoryFileSystem(files: ["/a": Data()])
        let err = await #expect(throws: FileSystemError.self) {
            try await fileSystem.list("/a")
        }
        if case .notADirectory = err { } else {
            Issue.record("expected .notADirectory, got \(String(describing: err))")
        }
    }

    // MARK: mkdir

    @Test func createDirectoryIntermediates() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.createDirectory("/a/b/c", intermediates: true)
        #expect(try await fileSystem.metadata("/a/b/c")?.kind == .directory)
    }

    @Test func createDirectoryNestedFailsWithoutIntermediates() async throws {
        let fileSystem = InMemoryFileSystem()
        await #expect(throws: FileSystemError.self) {
            try await fileSystem.createDirectory("/a/b/c", intermediates: false)
        }
    }

    @Test func createDirectoryAlreadyExists() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.createDirectory("/x", intermediates: false)
        let err = await #expect(throws: FileSystemError.self) {
            try await fileSystem.createDirectory("/x", intermediates: false)
        }
        if case .alreadyExists = err { } else {
            Issue.record("expected .alreadyExists, got \(String(describing: err))")
        }
    }

    // MARK: remove

    @Test func removeFile() async throws {
        let fileSystem = InMemoryFileSystem(files: ["/x": Data()])
        try await fileSystem.remove("/x", recursive: false)
        #expect(try await fileSystem.metadata("/x") == nil)
    }

    @Test func removeNonEmptyDirNeedsRecursive() async throws {
        let fileSystem = InMemoryFileSystem(files: ["/d/a": Data()])
        await #expect(throws: FileSystemError.self) {
            try await fileSystem.remove("/d", recursive: false)
        }
        try await fileSystem.remove("/d", recursive: true)
        #expect(try await fileSystem.metadata("/d") == nil)
    }

    @Test func removeEmptyDirOK() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.createDirectory("/empty", intermediates: false)
        try await fileSystem.remove("/empty", recursive: false)
        #expect(try await fileSystem.metadata("/empty") == nil)
    }

    // MARK: move + copy

    @Test func moveRenames() async throws {
        let fileSystem = InMemoryFileSystem(files: ["/a": Data("x".utf8)])
        try await fileSystem.move(from: "/a", to: "/b")
        #expect(try await fileSystem.metadata("/a") == nil)
        #expect(try await fileSystem.readData("/b") == Data("x".utf8))
    }

    @Test func copyDirectoryIsDeep() async throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/src/one": Data("1".utf8),
            "/src/nested/two": Data("2".utf8)
        ])
        try await fileSystem.copy(from: "/src", to: "/dst")
        #expect(try await fileSystem.readData("/dst/one") == Data("1".utf8))
        #expect(try await fileSystem.readData("/dst/nested/two") == Data("2".utf8))
        // Mutations on src don't bleed into dst (true deep copy).
        try await fileSystem.writeData(Data("mut".utf8), to: "/src/one", append: false)
        #expect(try await fileSystem.readData("/dst/one") == Data("1".utf8))
    }

    @Test func copyToExistingDestinationFails() async throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/a": Data("x".utf8),
            "/b": Data("y".utf8)
        ])
        let err = await #expect(throws: FileSystemError.self) {
            try await fileSystem.copy(from: "/a", to: "/b")
        }
        if case .alreadyExists = err { } else {
            Issue.record("expected .alreadyExists, got \(String(describing: err))")
        }
    }

    // MARK: canonicalize

    @Test func canonicalizeCollapsesDotDot() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.createDirectory("/a/b", intermediates: true)
        #expect(try await fileSystem.canonicalize("/a/b/..", allowMissing: false)
                == "/a")
    }

    @Test func canonicalizeStripsDot() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.createDirectory("/a", intermediates: true)
        #expect(try await fileSystem.canonicalize("/./a/./", allowMissing: false)
                == "/a")
    }

    // MARK: touch

    @Test func touchCreatesFile() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.touch("/a")
        let meta = try await fileSystem.metadata("/a")
        #expect(meta?.kind == .file)
        #expect(meta?.size == 0)
    }

    @Test func touchUpdatesMtime() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.writeData(Data("x".utf8), to: "/a", append: false)
        let beforeMeta = try await fileSystem.metadata("/a")!
        try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        try await fileSystem.touch("/a")
        let afterMeta = try await fileSystem.metadata("/a")!
        #expect(afterMeta.modifiedAt > beforeMeta.modifiedAt)
    }

    // MARK: openWrite streaming

    @Test func openWriteStreamsAppend() async throws {
        let fileSystem = InMemoryFileSystem()
        let sink = try await fileSystem.openWrite("/log", append: false)
        sink.write(Data("a\n".utf8))
        sink.write(Data("b\n".utf8))
        sink.finish()
        // Give the stream time to propagate (but onWrite is synchronous).
        let logData = try await fileSystem.readData("/log")
        #expect(String(bytes: logData, encoding: .utf8) == "a\nb\n")
    }
}
