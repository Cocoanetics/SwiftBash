import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// End-to-end tests for the filesystem-touching commands (`ls`, `mkdir`,
/// `rm`, `mv`, `cp`, `touch`). Each test uses a fresh temp directory
/// and `cd`s into it so relative paths in the script just work.
@Suite struct FilesystemCommandsTests {

    private func makeShell() -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("fs-cmds-\(UUID())")
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: ls

    @Test func lsEmptyDirPrintsNothing() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("ls")
        #expect(cap.stdout == "")
    }

    @Test func lsListsSortedEntries() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch zeta alpha gamma")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "alpha\ngamma\nzeta\n")
    }

    @Test func lsHidesDotfilesByDefault() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch visible .hidden")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "visible\n")
    }

    @Test func lsDashAShowsDotfiles() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch visible .hidden")
        try await cap.shell.run("ls -a")
        #expect(cap.stdout == ".hidden\nvisible\n")
    }

    @Test func lsOnMissingPathFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("ls nope")
        #expect(status == .failure)
        #expect(cap.stderr.contains("No such"))
    }

    @Test func lsOnRegularFilePrintsName() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch hello.txt")
        try await cap.shell.run("ls hello.txt")
        #expect(cap.stdout == "hello.txt\n")
    }

    // MARK: mkdir

    @Test func mkdirCreatesDirectory() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "sub\n")
    }

    @Test func mkdirNestedFailsWithoutP() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("mkdir a/b/c")
        #expect(status == .failure)
        #expect(!cap.stderr.isEmpty)
    }

    @Test func mkdirPCreatesParents() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p a/b/c")
        try await cap.shell.run("ls a/b")
        #expect(cap.stdout == "c\n")
    }

    @Test func mkdirPSilentOnExisting() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub")
        let status = try await cap.shell.run("mkdir -p sub")
        #expect(status == .success)
    }

    // MARK: rm

    @Test func rmRemovesFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch file.txt")
        try await cap.shell.run("rm file.txt")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "")
    }

    @Test func rmOnDirectoryNeedsRecursive() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub")
        try await cap.shell.run("touch sub/x")
        let status = try await cap.shell.run("rm sub")
        #expect(status == .failure)
    }

    @Test func rmRfRemovesDirectoryTree() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p sub/inner")
        try await cap.shell.run("touch sub/x sub/inner/y")
        try await cap.shell.run("rm -rf sub")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "")
    }

    @Test func rmMissingFailsWithoutForce() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("rm nope")
        #expect(status == .failure)
    }

    @Test func rmFForceMissingIsSilentSuccess() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("rm -f nope")
        #expect(status == .success)
        #expect(cap.stderr == "")
    }

    // MARK: mv

    @Test func mvRenames() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a.txt")
        try await cap.shell.run("mv a.txt b.txt")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "b.txt\n")
    }

    @Test func mvIntoDirectory() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir bucket")
        try await cap.shell.run("touch a.txt b.txt")
        try await cap.shell.run("mv a.txt b.txt bucket")
        try await cap.shell.run("ls bucket")
        #expect(cap.stdout == "a.txt\nb.txt\n")
    }

    @Test func mvMultipleSourcesToFileFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a b c")
        let status = try await cap.shell.run("mv a b c")
        #expect(status == .failure)
    }

    // MARK: cp

    @Test func cpCopiesFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch src.txt")
        try await cap.shell.run("cp src.txt dst.txt")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "dst.txt\nsrc.txt\n")
    }

    @Test func cpDirectoryWithoutRecursiveFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub")
        let status = try await cap.shell.run("cp sub dst")
        #expect(status == .failure)
        #expect(cap.stderr.contains("is a directory"))
    }

    @Test func cpDashRCopiesDirectoryTree() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p sub/inner")
        try await cap.shell.run("touch sub/x sub/inner/y")
        try await cap.shell.run("cp -r sub duplicate")
        try await cap.shell.run("ls duplicate/inner")
        #expect(cap.stdout == "y\n")
    }

    @Test func cpMultipleIntoDirectory() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir bucket")
        try await cap.shell.run("touch a b")
        try await cap.shell.run("cp a b bucket")
        try await cap.shell.run("ls bucket")
        #expect(cap.stdout == "a\nb\n")
    }

    // MARK: touch

    @Test func touchCreatesFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch new.txt")
        #expect(FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("new.txt")))
    }

    @Test func touchMultiplePaths() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a b c")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "a\nb\nc\n")
    }

    // MARK: integration

    @Test func catReadsFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let p = (dir as NSString).appendingPathComponent("hi.txt")
        try "line1\nline2\n".write(toFile: p, atomically: true, encoding: .utf8)
        try await cap.shell.run("cat hi.txt")
        #expect(cap.stdout == "line1\nline2\n")
    }

    @Test func fileSystemCanBeReplaced() async throws {
        // Prove the abstraction is the injection point: we swap in a
        // fake FS that rejects everything, and a command then reports
        // the error instead of hitting the real disk.
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.fileSystem = RejectingFileSystem()

        let status = try await cap.shell.run("ls")
        #expect(status == .failure)
        #expect(cap.stderr.contains("nope"))
    }
}

private struct RejectingFileSystem: FileSystem {
    func metadata(_ path: String) async throws -> FileMetadata? {
        throw FileSystemError.io("nope: \(path)")
    }
    func list(_ path: String) async throws -> [String] {
        throw FileSystemError.io("nope: \(path)")
    }
    func canonicalize(_ path: String, allowMissing: Bool) async throws -> String {
        throw FileSystemError.io("nope: \(path)")
    }
    func readData(_ path: String) async throws -> Data {
        throw FileSystemError.io("nope: \(path)")
    }
    func writeData(_ data: Data, to path: String, append: Bool) async throws {
        throw FileSystemError.io("nope: \(path)")
    }
    func touch(_ path: String) async throws {
        throw FileSystemError.io("nope: \(path)")
    }
    func createDirectory(_ path: String, intermediates: Bool) async throws {
        throw FileSystemError.io("nope: \(path)")
    }
    func remove(_ path: String, recursive: Bool) async throws {
        throw FileSystemError.io("nope: \(path)")
    }
    func move(from: String, to: String) async throws {
        throw FileSystemError.io("nope: \(from)")
    }
    func copy(from: String, to: String) async throws {
        throw FileSystemError.io("nope: \(from)")
    }
}
