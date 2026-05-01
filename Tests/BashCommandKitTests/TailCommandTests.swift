import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct TailCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: stdin

    @Test func defaultLastTenLines() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 20 | tail")
        #expect(cap.stdout
                == "11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n")
    }

    @Test func dashNLimitsCount() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 20 | tail -n 3")
        #expect(cap.stdout == "18\n19\n20\n")
    }

    @Test func fewerLinesThanRequestedJustEmitsAll() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\nb\nc\n")
        try await cap.shell.run("tail -n 10")
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func zeroPrintsNothing() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 5 | tail -n 0")
        #expect(cap.stdout == "")
    }

    @Test func noTrailingNewlineStillTails() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("only")
        try await cap.shell.run("tail -n 1")
        #expect(cap.stdout == "only\n")
    }

    @Test func emptyStdinPrintsNothing() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("")
        try await cap.shell.run("tail -n 5")
        #expect(cap.stdout == "")
    }

    // MARK: file mode

    @Test func tailReadsFile() async throws {
        let dir = NSTemporaryDirectory() + "tail-\(UUID())"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let p = (dir as NSString).appendingPathComponent("data")
        try "a\nb\nc\nd\ne\n".write(toFile: p, atomically: true, encoding: .utf8)
        let cap = makeShell()
        cap.shell.environment.workingDirectory = dir
        try await cap.shell.run("tail -n 2 data")
        #expect(cap.stdout == "d\ne\n")
    }

    @Test func tailMultipleFilesPrintsHeaders() async throws {
        let dir = NSTemporaryDirectory() + "tail-\(UUID())"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "1\n2\n3\n".write(
            toFile: (dir as NSString).appendingPathComponent("a"),
            atomically: true, encoding: .utf8)
        try "x\ny\nz\n".write(
            toFile: (dir as NSString).appendingPathComponent("b"),
            atomically: true, encoding: .utf8)

        let cap = makeShell()
        cap.shell.environment.workingDirectory = dir
        try await cap.shell.run("tail -n 2 a b")
        #expect(cap.stdout == "==> a <==\n2\n3\n\n==> b <==\ny\nz\n")
    }

    @Test func tailMissingFileFails() async throws {
        let cap = makeShell()
        cap.shell.environment.workingDirectory = NSTemporaryDirectory()
        let status = try await cap.shell.run("tail nope")
        #expect(status == .failure)
        #expect(cap.stderr.contains("No such"))
    }

    // MARK: pipeline

    @Test func headAndTailComposable() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 100 | head -n 20 | tail -n 5")
        #expect(cap.stdout == "16\n17\n18\n19\n20\n")
    }
}
#endif
