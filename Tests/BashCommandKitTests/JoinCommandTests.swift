import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct JoinCommandTests {

    private func makeShellWithDir() -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "join-\(UUID())"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    @Test func basicJoin() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "1 alice\n2 bob\n3 carol\n".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "1 100\n2 200\n3 300\n".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        try await cap.shell.run("join a b")
        #expect(cap.stdout == "1 alice 100\n2 bob 200\n3 carol 300\n")
    }

    @Test func customSeparator() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "1,a\n2,b\n".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "1,X\n2,Y\n".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        try await cap.shell.run("join -t , a b")
        #expect(cap.stdout == "1,a,X\n2,b,Y\n")
    }

    @Test func differentJoinFields() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "alice 1\nbob 2\n".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "1 100\n2 200\n".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        try await cap.shell.run("join -1 2 -2 1 a b")
        #expect(cap.stdout == "1 alice 100\n2 bob 200\n")
    }

    @Test func unpairedFromOne() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "1 a\n2 b\n3 c\n".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "1 X\n3 Z\n".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        try await cap.shell.run("join -a 1 a b")
        // 1 paired, 2 unpaired (printed as-is from a), 3 paired
        #expect(cap.stdout == "1 a X\n2 b\n3 c Z\n")
    }

    @Test func onlyUnpairedFromTwo() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "1 a\n2 b\n".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "1 X\n3 Z\n".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        try await cap.shell.run("join -v 2 a b")
        #expect(cap.stdout == "3 Z\n")
    }

    @Test func outputFormat() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "1 alice 100\n".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "1 ny\n".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        try await cap.shell.run("join -o '1.2,2.2,1.3' a b")
        #expect(cap.stdout == "alice ny 100\n")
    }

    @Test func ignoreCase() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "Alice 1\n".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "alice X\n".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        try await cap.shell.run("join -i a b")
        // Output uses the lowercased key for the join field.
        #expect(cap.stdout == "alice 1 X\n")
    }
}
#endif
