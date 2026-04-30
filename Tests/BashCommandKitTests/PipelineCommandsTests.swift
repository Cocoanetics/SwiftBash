import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct PipelineCommandsTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: cat

    @Test func catPassesStdinThrough() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("hello world\n")
        try await cap.shell.run("cat")
        #expect(cap.stdout == "hello world\n")
    }

    @Test func catInPipeline() async throws {
        let cap = makeShell()
        try await cap.shell.run("echo hello | cat")
        #expect(cap.stdout == "hello\n")
    }

    #if !os(Windows)
    @Test func catReadsFile() async throws {
        let tmp = NSTemporaryDirectory() + "cat-test-\(UUID()).txt"
        try "line1\nline2\n".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let cap = makeShell()
        try await cap.shell.run("cat \(tmp)")
        #expect(cap.stdout == "line1\nline2\n")
    }
    #endif

    @Test func catMissingFileFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("cat /definitely/not/a/file")
        #expect(status == .failure)
        #expect(!cap.stderr.isEmpty)
    }

    // MARK: wc

    // BSD/GNU `wc` right-aligns counts in 8-wide columns; expectations
    // below preserve that padding so output matches `/usr/bin/wc`.
    @Test func wcDefaultAllCounts() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"echo "hello world" | wc"#)
        // echo prints "hello world\n" → 1 line, 2 words, 12 bytes
        #expect(cap.stdout == "       1        2       12\n")
    }

    @Test func wcLinesOnly() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\nb\nc\n")
        try await cap.shell.run("wc -l")
        #expect(cap.stdout == "       3\n")
    }

    @Test func wcWordsOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"echo "one two three four" | wc -w"#)
        #expect(cap.stdout == "       4\n")
    }

    @Test func wcBytesOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"echo "abc" | wc -c"#)
        // "abc\n" is 4 bytes
        #expect(cap.stdout == "       4\n")
    }

    // MARK: head

    @Test func headDefault10Lines() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 20 | head")
        #expect(cap.stdout == "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
    }

    @Test func headWithDashN() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 20 | head -n 3")
        #expect(cap.stdout == "1\n2\n3\n")
    }

    @Test func headNoNewlineAtEndOfInput() async throws {
        // The streaming `head` always emits newline-terminated lines; an
        // input that lacked a trailing newline still gets one appended.
        // Diverges slightly from `/usr/bin/head` but consistent with the
        // streaming design and avoids buffering the whole input.
        let cap = makeShell()
        cap.shell.stdin = .string("only")
        try await cap.shell.run("head -n 1")
        #expect(cap.stdout == "only\n")
    }

    @Test func headZeroPrintsNothing() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 10 | head -n 0")
        #expect(cap.stdout == "")
    }

    // MARK: grep

    @Test func grepMatchesSubstring() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 20 | grep 1")
        // Matches 1, 10..19 — any line containing "1".
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(Set(lines) ==
                Set(["1", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19"]))
    }

    @Test func grepNoMatchFailsWithNoOutput() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("echo hello | grep nomatch")
        #expect(status == .failure)
        #expect(cap.stdout == "")
    }

    @Test func grepInvertMatch() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("apple\nbanana\napricot\n")
        try await cap.shell.run("grep -v ap")
        #expect(cap.stdout == "banana\n")
    }

    @Test func grepIgnoreCase() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("Hello\nWorld\nHELLO\n")
        try await cap.shell.run("grep -i hello")
        #expect(cap.stdout == "Hello\nHELLO\n")
    }

    // MARK: Realistic pipelines

    @Test func classicPipeline() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 100 | grep 7 | wc -l")
        // Numbers 1..100 containing '7': 7,17,27,37,47,57,67,70..79 (but 77 only once),
        // 87,97 = 7, 17, 27, 37, 47, 57, 67, 70,71,72,73,74,75,76,77,78,79, 87, 97 → 19.
        #expect(cap.stdout == "      19\n")
    }

    @Test func pipelineExitStatusIsLast() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("echo hi | grep nope")
        #expect(status == .failure)
    }

    @Test func pipelineWithCommandSubstitution() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"N=$(seq 5 | wc -l); echo $N"#)
        #expect(cap.stdout == "5\n")
    }
}
