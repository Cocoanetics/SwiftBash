import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

// swiftlint:disable:next type_body_length
@Suite(.timeLimit(.minutes(1))) struct EasyBatchTests {

    private func makeShell() throws -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString)
            .appendingPathComponent("easybatch-\(UUID())")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func write(_ contents: String, to path: String, in dir: String) {
        let full = (dir as NSString).appendingPathComponent(path)
        try? contents.write(toFile: full, atomically: true, encoding: .utf8)
    }

    // MARK: clear

    @Test func clearEmitsAnsi() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("clear")
        #expect(cap.stdout == "\u{1B}[2J\u{1B}[H")
    }

    // MARK: tac

    @Test func tacReversesStdinLines() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'a\\nb\\nc\\n' | tac")
        #expect(cap.stdout == "c\nb\na\n")
    }

    @Test func tacReadsFile() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        write("1\n2\n3\n", to: "f.txt", in: dir)
        try await cap.shell.run("tac f.txt")
        #expect(cap.stdout == "3\n2\n1\n")
    }

    // MARK: rev

    @Test func revReversesEachLine() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'hello\\nworld\\n' | rev")
        #expect(cap.stdout == "olleh\ndlrow\n")
    }

    @Test func revHandlesEmoji() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        // Reversal is by grapheme cluster, so the emoji stays whole.
        try await cap.shell.run("echo 'a🌍b' | rev")
        #expect(cap.stdout == "b🌍a\n")
    }

    // MARK: rmdir

    @Test func rmdirRemovesEmptyDir() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir empty")
        try await cap.shell.run("rmdir empty")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "")
    }

    @Test func rmdirFailsOnNonEmpty() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir d")
        try await cap.shell.run("touch d/f")
        let status = try await cap.shell.run("rmdir d")
        #expect(status == .failure)
        #expect(cap.stderr.contains("rmdir:"))
    }

    @Test func rmdirParentsClimbsUntilNonEmpty() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p a/b/c")
        try await cap.shell.run("rmdir -p a/b/c")
        // a, a/b, and a/b/c should all be gone.
        let status = try await cap.shell.run("ls a")
        #expect(status == .failure)
    }

    // MARK: tee

    @Test func teeFanoutsStdinToFileAndStdout() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo hi | tee out.txt")
        #expect(cap.stdout == "hi\n")
        let outPath = (dir as NSString).appendingPathComponent("out.txt")
        let written = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(written == "hi\n")
    }

    @Test func teeAppendDoesNotTruncate() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        let logPath = (dir as NSString).appendingPathComponent("log")
        try "first\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        try await cap.shell.run("echo second | tee -a log")
        let written = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(written == "first\nsecond\n")
    }

    @Test func teeToDevNullStillPassesStdoutThrough() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo hello | tee /dev/null")
        // /dev/null discarded; stdout still got it.
        #expect(cap.stdout == "hello\n")
    }

    // MARK: paste

    @Test func pasteJoinsLinesSideBySide() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        write("a\nb\nc\n", to: "x", in: dir)
        write("1\n2\n3\n", to: "y", in: dir)
        try await cap.shell.run("paste x y")
        #expect(cap.stdout == "a\t1\nb\t2\nc\t3\n")
    }

    @Test func pasteCustomDelimiter() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        write("a\nb\n", to: "x", in: dir)
        write("1\n2\n", to: "y", in: dir)
        try await cap.shell.run("paste -d , x y")
        #expect(cap.stdout == "a,1\nb,2\n")
    }

    @Test func pasteSerialJoinsOneFileAtATime() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        write("a\nb\nc\n", to: "x", in: dir)
        write("1\n2\n3\n", to: "y", in: dir)
        try await cap.shell.run("paste -s -d , x y")
        #expect(cap.stdout == "a,b,c\n1,2,3\n")
    }

    // MARK: comm

    @Test func commProducesThreeColumns() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        write("apple\nbanana\ncherry\n", to: "a", in: dir)
        write("banana\ncherry\ndate\n", to: "b", in: dir)
        try await cap.shell.run("comm a b")
        #expect(cap.stdout == "apple\n\t\tbanana\n\t\tcherry\n\tdate\n")
    }

    @Test func commSuppress23ShowsOnlyUniqueToFirst() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        write("a\nb\nc\n", to: "a", in: dir)
        write("b\n", to: "b", in: dir)
        try await cap.shell.run("comm -2 -3 a b")
        #expect(cap.stdout == "a\nc\n")
    }

    @Test func commWithStdin() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        write("a\nb\nc\n", to: "a", in: dir)
        try await cap.shell.run(
            "printf 'b\\n' | comm -1 -3 - a")
        // - is stdin (only in stdin), a is the file (suppress matches +
        // file-only). With -1 (suppress col1=stdin-only) and -3
        // (suppress common), what remains is col2 = file-only.
        #expect(cap.stdout == "a\nc\n")
    }

    // MARK: which / type / command -v

    @Test func whichReportsBinaryShadowPath() async throws {
        // `echo` is a bash built-in that *also* ships as /bin/echo on
        // macOS. Our `which` reports the shadow path so the result
        // looks identical to /usr/bin/which on a real system.
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("which echo")
        #expect(cap.stdout == "/bin/echo\n")
    }

    @Test func whichReportsShellBuiltinForPureBuiltin() async throws {
        // Pure shell built-ins (`cd`, `export`, …) have no file
        // shadow in `$PATH`. `which cd` reports the SwiftBash
        // convention `cd: shell built-in command`. Sandbox the FS
        // first so the host's `/usr/bin/cd` doesn't surface as a
        // file match.
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        cap.shell.fileSystem = InMemoryFileSystem()
        try await cap.shell.run("which cd")
        #expect(cap.stdout == "cd: shell built-in command\n")
    }

    @Test func whichExitsNonZeroForUnknown() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("which nope")
        #expect(status == .failure)
        #expect(cap.stdout == "")
    }

    @Test func typeReportsBuiltinForHybridWhenBuiltinWins() async throws {
        // `echo` is a hybrid: both a shell built-in AND a file at
        // `/bin/echo`. Built-in wins dispatch, so `type echo` reports
        // it as a built-in (real bash matches).
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("type echo")
        #expect(cap.stdout == "echo is a shell builtin\n")
    }

    @Test func typeReportsBinaryShadowPathForFileOnlyCommand() async throws {
        // `ls` has no built-in form, so `type ls` reports the file path.
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("type ls")
        #expect(cap.stdout == "ls is /bin/ls\n")
    }

    @Test func typeDashAReportsBuiltinAndFileForHybrid() async throws {
        // With `-a`, both the built-in entry and the file path show
        // up. Built-in first.
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("type -a echo")
        #expect(cap.stdout
            == "echo is a shell builtin\necho is /bin/echo\n")
    }

    @Test func typeReportsShellBuiltinForPureBuiltin() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("type cd")
        #expect(cap.stdout == "cd is a shell builtin\n")
    }

    @Test func commandDashVPrintsBuiltinNameForHybrid() async throws {
        // `echo` is a hybrid; built-in wins so `command -v` prints
        // just the name (matches bash).
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("command -v echo")
        #expect(cap.stdout == "echo\n")
    }

    @Test func commandDashVPrintsPathForFileOnlyCommand() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("command -v ls")
        #expect(cap.stdout == "/bin/ls\n")
    }

    @Test func commandDashVPrintsBuiltinName() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("command -v cd")
        #expect(cap.stdout == "cd\n")
    }

    @Test func commandDashVSilentOnUnknown() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("command -v nope")
        #expect(status == .failure)
        #expect(cap.stdout == "")
    }

    @Test func typeReportsFunctionForDefinedFunction() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("greet() { echo hi; }; type greet")
        #expect(cap.stdout == "greet is a function\n")
    }

    @Test func commandDashVRecognizesFunction() async throws {
        // Real bash's `command -v` succeeds for shell functions and
        // prints just the name. The dotfile idiom
        // `command -v foo >/dev/null && foo` relies on this.
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("greet() { :; }; command -v greet")
        #expect(cap.stdout == "greet\n")
    }

    // MARK: printenv

    @Test func printenvAllVariablesSorted() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.variables = [
            "PATH": "/usr/bin:/bin", "B": "two", "A": "one"
        ]
        try await cap.shell.run("printenv")
        #expect(cap.stdout == "A=one\nB=two\nPATH=/usr/bin:/bin\n")
    }

    @Test func printenvNamedVariablePrintsValue() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.variables = [
            "PATH": "/usr/bin:/bin", "FOO": "bar"
        ]
        try await cap.shell.run("printenv FOO")
        #expect(cap.stdout == "bar\n")
    }

    @Test func printenvMissingVariableExitsNonZero() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        let status = try await cap.shell.run("printenv NOPE")
        #expect(status == .failure)
        #expect(cap.stdout == "")
    }

    // MARK: od

    @Test func odDefaultIsOctal() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'AB' | od")
        // 'A'=0101, 'B'=0102. Final offset=0000002.
        #expect(cap.stdout == "0000000  101 102\n0000002\n")
    }

    @Test func odCharsRendersEscapes() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(#"printf 'a\nb' | od -c"#)
        // a, \n, b → "  a", " \n", "  b"
        #expect(cap.stdout == "0000000    a  \\n   b\n0000003\n")
    }

    // MARK: md5sum / sha1sum / sha256sum

    @Test func md5sumStdinFormat() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf '' | md5sum")
        #expect(cap.stdout
            == "d41d8cd98f00b204e9800998ecf8427e  -\n")
    }

    @Test func md5sumFileFormat() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        write("hello", to: "h", in: dir)
        try await cap.shell.run("md5sum h")
        #expect(cap.stdout
            == "5d41402abc4b2a76b9719d911017c592  h\n")
    }

    @Test func sha1sumStdin() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf '' | sha1sum")
        #expect(cap.stdout
            == "da39a3ee5e6b4b0d3255bfef95601890afd80709  -\n")
    }

    @Test func sha256sumStdin() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf '' | sha256sum")
        #expect(cap.stdout
            == "e3b0c44298fc1c149afbf4c8996fb924"
                + "27ae41e4649b934ca495991b7852b855  -\n")
    }

    // MARK: fgrep / egrep aliases

    @Test func egrepAcceptsExtendedRegex() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'foo\\nbar\\nbaz\\n' | egrep 'foo|baz'")
        #expect(cap.stdout == "foo\nbaz\n")
    }

    @Test func fgrepRunsAsSubstringSearch() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'apple\\nbanana\\n' | fgrep 'app'")
        #expect(cap.stdout == "apple\n")
    }
}
