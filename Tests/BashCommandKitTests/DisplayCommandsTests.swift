import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct DisplayCommandsTests {

    private func makeShellWithDir() -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "disp-\(UUID())"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }
    private func cleanup(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    @Test func treeBasic() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: dir + "/a", contents: Data())
        _ = FileManager.default.createFile(atPath: dir + "/sub/b", contents: Data())
        try await cap.shell.run("tree .")
        #expect(cap.stdout.contains(".\n"))
        #expect(cap.stdout.contains("├── a"))
        #expect(cap.stdout.contains("└── sub"))
        #expect(cap.stdout.contains("└── b"))
    }

    @Test func treeMaxDepth() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try FileManager.default.createDirectory(atPath: dir + "/a/b/c", withIntermediateDirectories: true)
        try await cap.shell.run("tree -L 1 .")
        #expect(cap.stdout.contains("a"))
        #expect(!cap.stdout.contains("b"))
    }

    @Test func stringsBinary() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        var data = Data([0xFF, 0x00, 0x01])
        data.append(Data("hello".utf8))
        data.append(Data([0x00]))
        data.append(Data("a".utf8))   // too short, skipped
        data.append(Data([0x00]))
        data.append(Data("world!".utf8))
        try data.write(to: URL(fileURLWithPath: dir + "/bin"))
        try await cap.shell.run("strings bin")
        #expect(cap.stdout.contains("hello"))
        #expect(cap.stdout.contains("world!"))
        #expect(!cap.stdout.contains("a\n"))
    }

    @Test func stringsMinLen() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        var d = Data("ab".utf8)
        d.append(0x00)
        d.append(Data("abcd".utf8))
        try d.write(to: URL(fileURLWithPath: dir + "/b"))
        try await cap.shell.run("strings -n 3 b")
        #expect(cap.stdout == "abcd\n")
    }

    @Test func columnTable() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        try await cap.shell.run("printf 'name age\\nalice 30\\nbob 25\\n' | column -t")
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        // First column padded; values aligned.
        #expect(lines[0].contains("name"))
        #expect(lines[1].contains("alice"))
    }
}
