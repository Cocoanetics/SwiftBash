import Testing
import Foundation
@testable import BashInterpreter

@Suite("ConfinedFileSystem confinement")
struct ConfinedFileSystemTests {

    /// Build a fresh sandbox dir + a confined wrapper rooted at it.
    private func makeSandbox() throws -> (root: URL, fs: ConfinedFileSystem) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-confined-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let backing = VirtualBinFileSystem(backing: RealFileSystem())
        let fs = ConfinedFileSystem(backing: backing, root: root.path)
        return (root, fs)
    }

    @Test("metadata returns nil for paths outside the sandbox")
    func metadataOutside() async throws {
        let (root, fs) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = try await fs.metadata("/etc/passwd")
        #expect(outside == nil)
    }

    @Test("readData throws notFound for paths outside the sandbox")
    func readOutside() async throws {
        let (root, fs) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: FileSystemError.self) {
            _ = try await fs.readData("/etc/passwd")
        }
    }

    @Test("reads inside the sandbox pass through to the backing FS")
    func readInside() async throws {
        let (root, fs) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let f = root.appendingPathComponent("hello.txt")
        try "world".write(to: f, atomically: true, encoding: .utf8)

        let data = try await fs.readData(f.path)
        #expect(String(decoding: data, as: UTF8.self) == "world")
    }

    @Test("writes land on disk inside the sandbox")
    func writeInside() async throws {
        let (root, fs) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let f = root.appendingPathComponent("out.txt")
        try await fs.writeData(Data("hi".utf8), to: f.path, append: false)
        #expect(FileManager.default.fileExists(atPath: f.path))
        #expect(try String(contentsOf: f, encoding: .utf8) == "hi")
    }

    @Test("writes outside the sandbox throw")
    func writeOutside() async throws {
        let (root, fs) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: FileSystemError.self) {
            try await fs.writeData(Data("nope".utf8),
                                   to: "/tmp/escaped.txt",
                                   append: false)
        }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/escaped.txt"))
    }

    @Test("synthetic /bin paths still resolve through the wrapper")
    func virtualBinPassesThrough() async throws {
        let (root, fs) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        // The backing chain is VirtualBinFileSystem(RealFileSystem()),
        // so /bin/cat is synthesised. The confining wrapper must let
        // it through or `which` and `ls /bin` break.
        let cat = try await fs.metadata("/bin/cat")
        #expect(cat != nil)
    }

    @Test("path standardisation collapses `..` escapes")
    func dotDotEscape() async throws {
        let (root, fs) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        // `<root>/../etc/passwd` standardises to `/<host>/etc/passwd`,
        // outside the sandbox — must reject.
        let escape = root.appendingPathComponent("../etc/passwd").path
        let m = try await fs.metadata(escape)
        #expect(m == nil)
    }
}
