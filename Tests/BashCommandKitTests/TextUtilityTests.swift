import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct TextUtilityTests {

    private func makeShell() -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString)
            .appendingPathComponent("textutil-\(UUID())")
        try! FileManager.default.createDirectory(
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
        let p = (dir as NSString).appendingPathComponent(path)
        try? contents.write(toFile: p, atomically: true, encoding: .utf8)
    }

    // MARK: tr

    @Test func trTranslatesAtoZ() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo hello | tr a-z A-Z")
        #expect(cap.stdout == "HELLO\n")
    }

    @Test func trDeletesChars() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo hello | tr -d l")
        #expect(cap.stdout == "heo\n")
    }

    @Test func trShorterSet2RepeatsLastChar() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // a→x, b→y, c→y, d→y
        try await cap.shell.run("echo abcd | tr abcd xy")
        #expect(cap.stdout == "xyyy\n")
    }

    @Test func trEscapeNewline() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // Replace `:` with newline in PATH-style input.
        try await cap.shell.run(#"echo a:b:c | tr ":" "\n""#)
        // echo emits "a:b:c\n"; tr replaces `:` with `\n` → "a\nb\nc\n".
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func trMissingSet1Fails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("echo hi | tr")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("SET1"))
    }

    // MARK: cut

    @Test func cutSingleField() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo a,b,c | cut -d , -f 2")
        #expect(cap.stdout == "b\n")
    }

    @Test func cutFieldList() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo a,b,c,d,e | cut -d , -f 1,3,5")
        #expect(cap.stdout == "a,c,e\n")
    }

    @Test func cutRange() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo a,b,c,d,e | cut -d , -f 2-4")
        #expect(cap.stdout == "b,c,d\n")
    }

    @Test func cutOpenRangeToEnd() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo a,b,c,d,e | cut -d , -f 3-")
        #expect(cap.stdout == "c,d,e\n")
    }

    @Test func cutDefaultDelimiterIsTab() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            #"printf 'a\tb\tc\n' | cut -f 2"#)
        #expect(cap.stdout == "b\n")
    }

    @Test func cutPassesThroughUndelimitedLines() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'no-delim\\na,b,c\\n' | cut -d , -f 1")
        #expect(cap.stdout == "no-delim\na\n")
    }

    @Test func cutReadsFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("x:y:z\np:q:r\n", to: "data", in: dir)
        try await cap.shell.run("cut -d : -f 2 data")
        #expect(cap.stdout == "y\nq\n")
    }

    @Test func cutInvalidFieldListFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("echo x | cut -d , -f abc")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("cut:"))
    }

    // MARK: base64

    @Test func base64EncodesStdin() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'hello' | base64")
        // "hello" → "aGVsbG8="
        #expect(cap.stdout == "aGVsbG8=\n")
    }

    @Test func base64DecodesStdin() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo aGVsbG8= | base64 -d")
        #expect(cap.stdout == "hello")
    }

    @Test func base64RoundTrip() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "echo 'roundtrip me' | base64 | base64 -d")
        #expect(cap.stdout == "roundtrip me\n")
    }

    @Test func base64InvalidDecodeFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("echo '!!!' | base64 -d")
        #expect(status == .failure)
        #expect(cap.stderr.contains("base64:"))
    }

    @Test func base64EncodesFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hi", to: "input", in: dir)
        try await cap.shell.run("base64 input")
        // "hi" → "aGk="
        #expect(cap.stdout == "aGk=\n")
    }

    // MARK: md5

    @Test func md5StdinPrintsBareHex() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // Empty input MD5 is the well-known d41d8cd98f00b204e9800998ecf8427e.
        try await cap.shell.run("printf '' | md5")
        #expect(cap.stdout == "d41d8cd98f00b204e9800998ecf8427e\n")
    }

    @Test func md5StringFlag() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(#"md5 -s hello"#)
        #expect(cap.stdout
            == "MD5 (\"hello\") = 5d41402abc4b2a76b9719d911017c592\n")
    }

    @Test func md5StringQuiet() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(#"md5 -q -s hello"#)
        #expect(cap.stdout == "5d41402abc4b2a76b9719d911017c592\n")
    }

    @Test func md5FilePrefixesName() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hello", to: "h.txt", in: dir)
        try await cap.shell.run("md5 h.txt")
        #expect(cap.stdout
            == "MD5 (h.txt) = 5d41402abc4b2a76b9719d911017c592\n")
    }

    @Test func md5MissingFileFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("md5 nope")
        #expect(status == .failure)
        #expect(cap.stderr.contains("nope"))
    }

    // MARK: xxd

    @Test func xxdHexDumpsHello() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'hello' | xxd")
        // 5 bytes → one row, hex padded to 16-byte width.
        #expect(cap.stdout
            == "00000000: 6865 6c6c 6f                             hello\n")
    }

    @Test func xxdHandlesMultipleRows() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // 16 + 1 = 17 bytes → two rows.
        try await cap.shell.run(
            "printf '0123456789abcdefX' | xxd")
        #expect(cap.stdout == """
            00000000: 3031 3233 3435 3637 3839 6162 6364 6566  0123456789abcdef
            00000010: 58                                       X

            """)
    }

    @Test func xxdReplacesNonPrintableBytes() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // Two newlines at start, then `ab`. Newline (0x0a) is not
        // printable in xxd's column.
        try await cap.shell.run(#"printf '\n\nab' | xxd"#)
        #expect(cap.stdout
            == "00000000: 0a0a 6162                                ..ab\n")
    }

    @Test func xxdReadsFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("AB", to: "two", in: dir)
        try await cap.shell.run("xxd two")
        #expect(cap.stdout
            == "00000000: 4142                                     AB\n")
    }
}
#endif
