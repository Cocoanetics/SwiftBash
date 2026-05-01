import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct DuCommandTests {

    private func makeShellWithDir() -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "du-\(UUID())"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    @Test func summaryFlag() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try Data(repeating: 0x41, count: 1024).write(to: URL(fileURLWithPath: dir + "/a"))
        try Data(repeating: 0x41, count: 2048).write(to: URL(fileURLWithPath: dir + "/b"))
        try await cap.shell.run("du -s .")
        // 3 KiB total, rounded up to 3
        let parts = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        #expect(parts.count == 2)
        #expect(parts[0] == "3")
    }

    @Test func bytesMode() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try Data(repeating: 0x41, count: 100).write(to: URL(fileURLWithPath: dir + "/a"))
        try await cap.shell.run("du -b -s .")
        let parts = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        #expect(parts[0] == "100")
    }

    @Test func humanReadable() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: dir + "/big"))
        try await cap.shell.run("du -h -s .")
        #expect(cap.stdout.contains("K"))
    }

    @Test func recursiveListing() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1024).write(to: URL(fileURLWithPath: dir + "/sub/a"))
        try await cap.shell.run("du -k .")
        // Should report sub directory and total
        #expect(cap.stdout.contains("sub"))
    }

    @Test func allFiles() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try Data(repeating: 0x41, count: 100).write(to: URL(fileURLWithPath: dir + "/file"))
        try await cap.shell.run("du -a .")
        #expect(cap.stdout.contains("file"))
    }
}
#endif
