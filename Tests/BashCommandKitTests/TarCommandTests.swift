import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct TarCommandTests {

    private func makeShellWithDir() -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "tar-\(UUID())"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    #if !os(Windows)
    @Test func roundTripFiles() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "alpha".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "beta".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        // Pack
        try await cap.shell.run("tar -cf archive.tar a.txt b.txt")
        // Move them aside, then extract.
        try FileManager.default.removeItem(atPath: dir + "/a.txt")
        try FileManager.default.removeItem(atPath: dir + "/b.txt")
        try await cap.shell.run("tar -xf archive.tar")
        let a = try String(contentsOfFile: dir + "/a.txt", encoding: .utf8)
        let b = try String(contentsOfFile: dir + "/b.txt", encoding: .utf8)
        #expect(a == "alpha")
        #expect(b == "beta")
    }
    #endif

    #if !os(Windows)
    @Test func listArchive() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "x".write(toFile: dir + "/one", atomically: true, encoding: .utf8)
        try await cap.shell.run("tar -cf x.tar one")
        try await cap.shell.run("tar -tf x.tar")
        #expect(cap.stdout.contains("one"))
    }
    #endif

    #if !os(Windows)
    @Test func directoryRoundTrip() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try "data".write(toFile: dir + "/sub/inner", atomically: true, encoding: .utf8)
        try await cap.shell.run("tar -cf d.tar sub")
        try FileManager.default.removeItem(atPath: dir + "/sub")
        try await cap.shell.run("tar -xf d.tar")
        let s = try String(contentsOfFile: dir + "/sub/inner", encoding: .utf8)
        #expect(s == "data")
    }
    #endif

    @Test func verboseOnCreate() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "x".write(toFile: dir + "/file", atomically: true, encoding: .utf8)
        try await cap.shell.run("tar -cvf out.tar file")
        #expect(cap.stderr.contains("file"))
    }
}
