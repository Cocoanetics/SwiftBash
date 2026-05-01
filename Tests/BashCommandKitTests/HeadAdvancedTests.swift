import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct HeadAdvancedTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func headBytes() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf abcdefghij | head -c 4")
        #expect(cap.stdout == "abcd")
    }

    @Test func headBytesLong() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf abcdefghij | head --bytes=3")
        #expect(cap.stdout == "abc")
    }

    @Test func headTrailingLines() async throws {
        let cap = makeShell()
        // -n -2 → all but the last 2 lines.
        try await cap.shell.run("seq 5 | head -n -2")
        #expect(cap.stdout == "1\n2\n3\n")
    }

    @Test func headTrailingBytes() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf abcdefghij | head -c -3")
        #expect(cap.stdout == "abcdefg")
    }

    #if !os(Windows)
    @Test func headMultipleFilesPrintsHeaders() async throws {
        let cap = makeShell()
        let dir = NSTemporaryDirectory() + "head-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "a1\na2\n".write(toFile: dir + "/one", atomically: true, encoding: .utf8)
        try "b1\nb2\n".write(toFile: dir + "/two", atomically: true, encoding: .utf8)
        try await cap.shell.run("head -n 1 \(dir)/one \(dir)/two")
        #expect(cap.stdout.contains("==> \(dir)/one <==\n"))
        #expect(cap.stdout.contains("==> \(dir)/two <==\n"))
        #expect(cap.stdout.contains("a1"))
        #expect(cap.stdout.contains("b1"))
    }
    #endif

    #if !os(Windows)
    @Test func headQuietSuppressesHeaders() async throws {
        let cap = makeShell()
        let dir = NSTemporaryDirectory() + "head-q-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "a\n".write(toFile: dir + "/x", atomically: true, encoding: .utf8)
        try "b\n".write(toFile: dir + "/y", atomically: true, encoding: .utf8)
        try await cap.shell.run("head -q -n 1 \(dir)/x \(dir)/y")
        #expect(cap.stdout == "a\nb\n")
    }
    #endif

    @Test func headVerboseAddsHeader() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'x\\ny\\n' | head -v -n 1")
        #expect(cap.stdout.contains("==> standard input <=="))
        #expect(cap.stdout.contains("x"))
    }
}
#endif
