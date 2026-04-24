import XCTest
@testable import BashInterpreter
@testable import BashCommandKit

final class PipelineCommandsTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: cat

    func testCatPassesStdinThrough() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("hello world\n")
        try await cap.shell.run("cat")
        XCTAssertEqual(cap.stdout, "hello world\n")
    }

    func testCatInPipeline() async throws {
        let cap = makeShell()
        try await cap.shell.run("echo hello | cat")
        XCTAssertEqual(cap.stdout, "hello\n")
    }

    func testCatReadsFile() async throws {
        let tmp = NSTemporaryDirectory() + "cat-test-\(UUID()).txt"
        try "line1\nline2\n".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let cap = makeShell()
        try await cap.shell.run("cat \(tmp)")
        XCTAssertEqual(cap.stdout, "line1\nline2\n")
    }

    func testCatMissingFileFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("cat /definitely/not/a/file")
        XCTAssertEqual(status, .failure)
        XCTAssertFalse(cap.stderr.isEmpty)
    }

    // MARK: wc

    func testWcDefaultAllCounts() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"echo "hello world" | wc"#)
        // echo prints "hello world\n" → 1 line, 2 words, 12 bytes
        XCTAssertEqual(cap.stdout, "1 2 12\n")
    }

    func testWcLinesOnly() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a\nb\nc\n")
        try await cap.shell.run("wc -l")
        XCTAssertEqual(cap.stdout, "3\n")
    }

    func testWcWordsOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"echo "one two three four" | wc -w"#)
        XCTAssertEqual(cap.stdout, "4\n")
    }

    func testWcBytesOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"echo "abc" | wc -c"#)
        // "abc\n" is 4 bytes
        XCTAssertEqual(cap.stdout, "4\n")
    }

    // MARK: head

    func testHeadDefault10Lines() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 20 | head")
        XCTAssertEqual(cap.stdout, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
    }

    func testHeadWithDashN() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 20 | head -n 3")
        XCTAssertEqual(cap.stdout, "1\n2\n3\n")
    }

    func testHeadNoNewlineAtEndOfInput() async throws {
        // The streaming `head` always emits newline-terminated lines; an
        // input that lacked a trailing newline still gets one appended.
        // Diverges slightly from `/usr/bin/head` but consistent with the
        // streaming design and avoids buffering the whole input.
        let cap = makeShell()
        cap.shell.stdin = .string("only")
        try await cap.shell.run("head -n 1")
        XCTAssertEqual(cap.stdout, "only\n")
    }

    func testHeadZeroPrintsNothing() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 10 | head -n 0")
        XCTAssertEqual(cap.stdout, "")
    }

    // MARK: grep

    func testGrepMatchesSubstring() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 20 | grep 1")
        // Matches 1, 10..19 — any line containing "1".
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(Set(lines),
                       Set(["1", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19"]))
    }

    func testGrepNoMatchFailsWithNoOutput() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("echo hello | grep nomatch")
        XCTAssertEqual(status, .failure)
        XCTAssertEqual(cap.stdout, "")
    }

    func testGrepInvertMatch() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("apple\nbanana\napricot\n")
        try await cap.shell.run("grep -v ap")
        XCTAssertEqual(cap.stdout, "banana\n")
    }

    func testGrepIgnoreCase() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("Hello\nWorld\nHELLO\n")
        try await cap.shell.run("grep -i hello")
        XCTAssertEqual(cap.stdout, "Hello\nHELLO\n")
    }

    // MARK: Realistic pipelines

    func testClassicPipeline() async throws {
        let cap = makeShell()
        try await cap.shell.run("seq 100 | grep 7 | wc -l")
        // Numbers 1..100 containing '7': 7,17,27,37,47,57,67,70..79 (but 77 only once),
        // 87,97 = 7, 17, 27, 37, 47, 57, 67, 70,71,72,73,74,75,76,77,78,79, 87, 97 → 19.
        XCTAssertEqual(cap.stdout, "19\n")
    }

    func testPipelineExitStatusIsLast() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("echo hi | grep nope")
        XCTAssertEqual(status, .failure)
    }

    func testPipelineWithCommandSubstitution() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"N=$(seq 5 | wc -l); echo $N"#)
        XCTAssertEqual(cap.stdout, "5\n")
    }
}
