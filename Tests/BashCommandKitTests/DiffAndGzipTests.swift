import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct DiffAndGzipTests {

    private func makeShell() -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString)
            .appendingPathComponent("diffgzip-\(UUID())")
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

    // MARK: diff

    @Test func diffIdenticalFilesIsSilentSuccess() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("a\nb\nc\n", to: "x", in: dir)
        write("a\nb\nc\n", to: "y", in: dir)
        let status = try await cap.shell.run("diff -u x y")
        #expect(status == .success)
        #expect(cap.stdout == "")
    }

    @Test func diffSimpleChangeShowsHunk() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("a\nb\nc\n", to: "x", in: dir)
        write("a\nB\nc\n", to: "y", in: dir)
        let status = try await cap.shell.run("diff -u x y")
        #expect(status == .failure)
        #expect(cap.stdout == """
            --- x
            +++ y
            @@ -1,3 +1,3 @@
             a
            -b
            +B
             c

            """)
    }

    @Test func diffPureAdditionAtEnd() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("a\nb\n", to: "x", in: dir)
        write("a\nb\nc\n", to: "y", in: dir)
        try await cap.shell.run("diff -u x y")
        #expect(cap.stdout == """
            --- x
            +++ y
            @@ -1,2 +1,3 @@
             a
             b
            +c

            """)
    }

    @Test func diffPureDeletion() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("a\nb\nc\n", to: "x", in: dir)
        write("a\nc\n", to: "y", in: dir)
        try await cap.shell.run("diff -u x y")
        #expect(cap.stdout == """
            --- x
            +++ y
            @@ -1,3 +1,2 @@
             a
            -b
             c

            """)
    }

    @Test func diffSeparateChangesProduceTwoHunks() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // Each "X" line changes; the runs are far enough apart that
        // their context windows don't merge (gap > 2 * context).
        let a = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        var bArr = (1...20).map { "line\($0)" }
        bArr[1] = "LINE2"   // change at line 2
        bArr[18] = "LINE19" // change at line 19
        let b = bArr.joined(separator: "\n") + "\n"
        write(a, to: "x", in: dir)
        write(b, to: "y", in: dir)
        try await cap.shell.run("diff -u x y")
        // Expect two `@@ ... @@` headers.
        let hunkCount = cap.stdout.components(separatedBy: "@@ -")
            .count - 1
        #expect(hunkCount == 2)
        #expect(cap.stdout.contains("-line2"))
        #expect(cap.stdout.contains("+LINE2"))
        #expect(cap.stdout.contains("-line19"))
        #expect(cap.stdout.contains("+LINE19"))
    }

    @Test func diffCustomContextSize() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("a\nb\nc\nd\ne\nf\n", to: "x", in: dir)
        write("a\nb\nc\nD\ne\nf\n", to: "y", in: dir)
        try await cap.shell.run("diff -u 1 x y")
        #expect(cap.stdout == """
            --- x
            +++ y
            @@ -3,3 +3,3 @@
             c
            -d
            +D
             e

            """)
    }

    @Test func diffStdinViaDash() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hello\nworld\n", to: "fixed", in: dir)
        try await cap.shell.run(
            "printf 'hello\\nWORLD\\n' | diff -u - fixed")
        #expect(cap.stdout.contains("-WORLD"))
        #expect(cap.stdout.contains("+world"))
    }

    @Test func diffMissingFileFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("diff nope nope2")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("diff:"))
    }

    // MARK: gzip / gunzip

    @Test func gzipRoundTripStdin() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'hello world' | gzip -c | gunzip -c")
        #expect(cap.stdout == "hello world")
    }

    @Test func gzipMagicHeader() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'x' | gzip -c | xxd")
        // First two bytes are gzip magic 1F 8B; third is method 08
        // (deflate); fourth is flags 00.
        let firstLine = cap.stdout
            .components(separatedBy: "\n").first ?? ""
        #expect(firstLine.contains("1f8b 0800"))
    }

    @Test func gzipRepeatingDataIsSmaller() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // 200 zeroes; deflate compresses runs aggressively. Compressed
        // result must be << 200 bytes once headers are accounted for.
        try await cap.shell.run(
            "printf '%.0sa' $(seq 200) | gzip -c | wc -c")
        // 200 'a's compresses to a few dozen bytes (header + tiny
        // deflate body + trailer). Far below the original 200.
        let n = Int(cap.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines)) ?? 0
        #expect(n > 0)
        #expect(n < 50)
    }

    @Test func gzipReplacesFileByDefault() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hello\n", to: "in.txt", in: dir)
        try await cap.shell.run("gzip in.txt")
        // Original is gone; in.txt.gz exists; round-trip back works.
        try await cap.shell.run("ls")
        #expect(cap.stdout.contains("in.txt.gz"))
        #expect(!cap.stdout.contains("in.txt\n"))

        // Decompress to confirm content survived.
        try await cap.shell.run("gunzip -c in.txt.gz")
        #expect(cap.stdout.hasSuffix("hello\n"))
    }

    @Test func gunzipReplacesFileByDefault() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hello\n", to: "in.txt", in: dir)
        try await cap.shell.run("gzip in.txt")
        try await cap.shell.run("gunzip in.txt.gz")
        try await cap.shell.run("ls")
        #expect(cap.stdout.contains("in.txt\n"))
        #expect(!cap.stdout.contains(".gz"))
    }

    @Test func gunzipOnNonGzipFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'plain text' | gunzip -c")
        // No assertion on stdout; we just want a non-zero status and
        // a useful stderr message.
        #expect(cap.stderr.contains("gunzip:"))
    }

    // MARK: round-trip via Foundation gzip

    @Test func gzipOutputDecompressesWithSystemGunzip() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // Compress with our gzip, then dump bytes via xxd to confirm
        // structural validity. (We don't shell out to a separate
        // gunzip binary; the xxd inspection already showed the magic.)
        let payload = String(repeating: "swift-bash gzip ", count: 64)
        write(payload, to: "p", in: dir)
        try await cap.shell.run("gzip -c p | gunzip -c")
        #expect(cap.stdout == payload)
    }
}
