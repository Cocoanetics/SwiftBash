import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct SedAdvancedTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    /// Run a sed pipeline and return stdout.
    private func sed(_ input: String, _ script: String,
                     extra: String = "") async throws -> String {
        let cap = makeShell()
        let cmd = "printf %s '\(input.replacingOccurrences(of: "'", with: "'\\''"))' | sed \(extra) '\(script.replacingOccurrences(of: "'", with: "'\\''"))'"
        try await cap.shell.run(cmd)
        return cap.stdout
    }

    // MARK: - Address ranges

    @Test func numericRange() async throws {
        let out = try await sed("a\nb\nc\nd\ne\n", "2,4d")
        #expect(out == "a\ne\n")
    }

    @Test func dollarLastLine() async throws {
        let out = try await sed("a\nb\nc\n", "$d")
        #expect(out == "a\nb\n")
    }

    @Test func patternRange() async throws {
        let out = try await sed("a\nSTART\nb\nc\nEND\nd\n",
                                "/START/,/END/d")
        #expect(out == "a\nd\n")
    }

    @Test func stepAddress() async throws {
        // Print every other line (lines 1, 3, 5).
        let out = try await sed("1\n2\n3\n4\n5\n", "1~2!d")
        #expect(out == "1\n3\n5\n")
    }

    @Test func relativeOffsetRange() async throws {
        // /b/,+2 should match the line containing "b" plus the next 2.
        let out = try await sed("a\nb\nc\nd\ne\n", "/b/,+2p", extra: "-n")
        #expect(out == "b\nc\nd\n")
    }

    @Test func addressNegation() async throws {
        let out = try await sed("a\nb\nc\n", "2!d")
        #expect(out == "b\n")
    }

    // MARK: - Hold space

    @Test func holdAndGet() async throws {
        // Save line 1 to hold, replace pattern with hold on every line.
        let out = try await sed("first\nsecond\nthird\n",
                                "1h;2,$g")
        #expect(out == "first\nfirst\nfirst\n")
    }

    @Test func exchange() async throws {
        // Save line 1 in hold, then on line 2 swap and append: pattern
        // becomes the original line 1 followed by line 2.
        let out = try await sed("a\nb\n", "1{h;d};2{x;G}")
        #expect(out == "a\nb\n")
    }

    @Test func reverseFile() async throws {
        // Classic 'tac' via 1!G;h;$!d
        let out = try await sed("1\n2\n3\n", "1!G;h;$!d")
        #expect(out == "3\n2\n1\n")
    }

    // MARK: - Branching

    @Test func branchToEnd() async throws {
        // skip the substitute on line 2 by branching to end.
        let out = try await sed("a\nb\nc\n", "2b;s/./X/")
        #expect(out == "X\nb\nX\n")
    }

    @Test func branchToLabel() async throws {
        // Replace 'x' with 'X' repeatedly via :loop / t loop
        let out = try await sed("xxxx\n", ":a;s/x/X/;ta")
        #expect(out == "XXXX\n")
    }

    @Test func branchOnNoSubst() async throws {
        // Print a marker only on lines where substitution did NOT happen.
        let out = try await sed("foo\nbar\nfoo\n",
                                "s/foo/X/;Tnope;b end;:nope;s/^/!/;:end")
        #expect(out == "X\n!bar\nX\n")
    }

    // MARK: - Multi-line

    @Test func nextAppend() async throws {
        // Join consecutive lines with ;
        let out = try await sed("a\nb\nc\nd\n", "N;s/\\n/;/")
        #expect(out == "a;b\nc;d\n")
    }

    @Test func nextCommand() async throws {
        // n prints, then reads next line. Substitute applies to the
        // *new* current line.
        let out = try await sed("a\nb\nc\n", "n;s/./X/")
        #expect(out == "a\nX\nc\n")
    }

    @Test func deleteFirstLineRestarts() async throws {
        // D should drop up to first newline and restart the cycle.
        let out = try await sed("a\nb\nc\n", "$!{N;D}")
        #expect(out == "c\n")
    }

    // MARK: - Transliterate

    @Test func transliterate() async throws {
        let out = try await sed("Hello, World\n", "y/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/")
        #expect(out == "HELLO, WORLD\n")
    }

    @Test func transliterateUnequalLengthErrors() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("echo x | sed 'y/ab/c/'")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("sed:"))
    }

    // MARK: - Substitute flags

    @Test func substituteIgnoreCase() async throws {
        let out = try await sed("Hello\nHELLO\n", "s/hello/x/i")
        #expect(out == "x\nx\n")
    }

    @Test func substituteNthOccurrence() async throws {
        let out = try await sed("a a a a\n", "s/a/X/3")
        #expect(out == "a a X a\n")
    }

    @Test func substituteEmptyPatternReuse() async throws {
        // empty regex // reuses last pattern.
        let out = try await sed("foo bar foo\n", "s/foo/x/;s//y/")
        #expect(out == "x bar y\n")
    }

    // MARK: - Append / insert / change

    @Test func appendText() async throws {
        let out = try await sed("a\nb\n", "1a after")
        #expect(out == "a\nafter\nb\n")
    }

    @Test func insertText() async throws {
        let out = try await sed("a\nb\n", "2i before")
        #expect(out == "a\nbefore\nb\n")
    }

    @Test func changeText() async throws {
        let out = try await sed("a\nb\nc\n", "2c CHANGED")
        #expect(out == "a\nCHANGED\nc\n")
    }

    // MARK: - Misc commands

    @Test func lineNumberCommand() async throws {
        let out = try await sed("a\nb\nc\n", "=")
        #expect(out == "1\na\n2\nb\n3\nc\n")
    }

    @Test func quitCommand() async throws {
        let out = try await sed("1\n2\n3\n4\n", "2q")
        #expect(out == "1\n2\n")
    }

    @Test func quitSilent() async throws {
        let out = try await sed("1\n2\n3\n", "2Q")
        #expect(out == "1\n")
    }

    @Test func zapCommand() async throws {
        let out = try await sed("hello\n", "z")
        #expect(out == "\n")
    }

    @Test func listCommand() async throws {
        let out = try await sed("a\tb\n", "l", extra: "-n")
        // \t becomes \\t, line ends with $
        #expect(out == "a\\tb$\n")
    }

    // MARK: - POSIX classes

    @Test func posixClass() async throws {
        let out = try await sed("hello 123 world\n", "s/[[:digit:]]\\+/N/")
        #expect(out == "hello N world\n")
    }

    // MARK: - Groups

    @Test func groupCommands() async throws {
        let out = try await sed("a\nb\nc\n", "2{s/./X/;p}")
        #expect(out == "a\nX\nX\nc\n")
    }

    // MARK: - Multiple -e

    @Test func multipleExpressions() async throws {
        let cap = makeShell()
        try await cap.shell.run("echo abc | sed -e 's/a/A/' -e 's/c/C/'")
        #expect(cap.stdout == "AbC\n")
    }

    // MARK: - #n shebang

    @Test func hashNComment() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\nb\\n' | sed '#n\\np'")
        #expect(cap.stdout == "a\nb\n")
    }

    // MARK: - File I/O

    #if !os(Windows)
    @Test func readFileCommand() async throws {
        let cap = makeShell()
        let dir = NSTemporaryDirectory() + "sed-r-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/data.txt"
        try "from-file\n".write(toFile: path, atomically: true, encoding: .utf8)
        try await cap.shell.run("printf 'a\\nb\\n' | sed '1r \(path)'")
        #expect(cap.stdout == "a\nfrom-file\nb\n")
    }
    #endif

    #if !os(Windows)
    @Test func writeFileCommand() async throws {
        let cap = makeShell()
        let dir = NSTemporaryDirectory() + "sed-w-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/out.txt"
        try await cap.shell.run("printf 'a\\nb\\n' | sed '/a/w \(path)'")
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "a\n")
    }
    #endif
}
#endif
