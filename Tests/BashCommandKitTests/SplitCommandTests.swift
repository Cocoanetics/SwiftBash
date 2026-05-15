import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct SplitCommandTests {

    private func makeShellWithDir() throws -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "split-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    @Test func defaultLines() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("seq 5 | split -l 2")
        // Expect xaa, xab, xac
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        #expect(names == ["xaa", "xab", "xac"])
        #expect(try String(contentsOfFile: dir + "/xaa", encoding: .utf8) == "1\n2\n")
        #expect(try String(contentsOfFile: dir + "/xab", encoding: .utf8) == "3\n4\n")
        #expect(try String(contentsOfFile: dir + "/xac", encoding: .utf8) == "5\n")
    }

    @Test func bytesMode() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("printf abcdefghij | split -b 4")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        #expect(names == ["xaa", "xab", "xac"])
        #expect(try String(contentsOfFile: dir + "/xaa", encoding: .utf8) == "abcd")
        #expect(try String(contentsOfFile: dir + "/xab", encoding: .utf8) == "efgh")
        #expect(try String(contentsOfFile: dir + "/xac", encoding: .utf8) == "ij")
    }

    @Test func numericSuffixes() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("seq 4 | split -l 2 -d")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        #expect(names == ["x00", "x01"])
    }

    @Test func customPrefix() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("seq 2 | split -l 1 - chunk")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        #expect(names == ["chunkaa", "chunkab"])
    }

    @Test func additionalSuffix() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("seq 2 | split -l 1 --additional-suffix=.txt")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        #expect(names == ["xaa.txt", "xab.txt"])
    }

    @Test func sizeWithSuffix() async throws {
        let (cap, dir) = try makeShellWithDir(); defer { cleanup(dir) }
        // 1K size unit
        _ = FileManager.default.createFile(
            atPath: dir + "/big",
            contents: Data(repeating: 0x41, count: 3072))
        try await cap.shell.run("split -b 1K big")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0 != "big" }.sorted()
        #expect(names == ["xaa", "xab", "xac"])
    }
}
