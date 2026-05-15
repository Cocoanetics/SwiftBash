import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct NlCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: stdin

    @Test func defaultNumbersNonEmptyLines() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\n\nb\n")
        try await cap.shell.run("nl")
        #expect(cap.stdout == "     1\ta\n\n     2\tb\n")
    }

    @Test func bodyAllNumbersEveryLine() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\n\nb\n")
        try await cap.shell.run("nl -b a")
        #expect(cap.stdout == "     1\ta\n     2\t\n     3\tb\n")
    }

    @Test func bodyNoneSkipsAllNumbering() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\nb\n")
        try await cap.shell.run("nl -b n")
        #expect(cap.stdout == "a\nb\n")
    }

    @Test func customWidthRightAligns() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("x\ny\n")
        try await cap.shell.run("nl -w 3")
        #expect(cap.stdout == "  1\tx\n  2\ty\n")
    }

    @Test func customSeparator() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\nb\n")
        try await cap.shell.run("nl -w 1 -s ': '")
        #expect(cap.stdout == "1: a\n2: b\n")
    }

    @Test func customStartingNumber() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\nb\n")
        try await cap.shell.run("nl -w 2 -v 10")
        #expect(cap.stdout == "10\ta\n11\tb\n")
    }

    @Test func emptyStdinPrintsNothing() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("")
        try await cap.shell.run("nl")
        #expect(cap.stdout == "")
    }

    @Test func invalidBodyStyleFails() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\n")
        let status = try await cap.shell.run("nl -b z")
        // POSIX usage-error exit (2), not generic 1.
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("invalid body numbering style"))
    }

    @Test func combinedShortFlag() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\n\nb\n")
        try await cap.shell.run("nl -ba")
        // -ba should number all lines including the blank one.
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].contains("1"))
        #expect(lines[1].contains("2"))
        #expect(lines[2].contains("3"))
    }

    // MARK: file mode

    @Test func numbersFileContents() async throws {
        let dir = NSTemporaryDirectory() + "nl-\(UUID())"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("data")
        try "one\ntwo\nthree\n".write(
            toFile: path, atomically: true, encoding: .utf8)
        let cap = makeShell()
        cap.shell.environment.workingDirectory = dir
        try await cap.shell.run("nl -w 1 data")
        #expect(cap.stdout == "1\tone\n2\ttwo\n3\tthree\n")
    }

    @Test func missingFileFails() async throws {
        let cap = makeShell()
        cap.shell.environment.workingDirectory = NSTemporaryDirectory()
        let status = try await cap.shell.run("nl nope")
        #expect(status == .failure)
        #expect(cap.stderr.contains("No such"))
    }

    // MARK: pipeline

    @Test func composesWithSeqAndHead() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 5 | nl -w 1 | head -n 2")
        #expect(cap.stdout == "1\t1\n2\t2\n")
    }
}
