import Testing
import Foundation
@testable import BashInterpreter

@Suite struct RedirectionTests {

    private func makeShell() -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("redir-\(UUID())")
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func readFile(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    // MARK: > (truncate)

    @Test func truncateCreatesFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo hello > out.txt")
        #expect(readFile("\(dir)/out.txt") == "hello\n")
        #expect(cap.stdout == "",
                "stdout must NOT receive the redirected bytes")
    }

    @Test func truncateOverwritesExistingContent() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo first > out.txt")
        try await cap.shell.run("echo second > out.txt")
        #expect(readFile("\(dir)/out.txt") == "second\n")
        _ = cap
    }

    @Test func truncateWithMultipleWrites() async throws {
        // A single command that produces multiple writes should still
        // end up with all output in the file (streaming, not clobbered
        // after each write).
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        cap.shell.register(name: "emit") { _ in
            Shell.current.stdout("a\n")
            Shell.current.stdout("b\n")
            Shell.current.stdout("c\n")
            return .success
        }
        try await cap.shell.run("emit > out.txt")
        #expect(readFile("\(dir)/out.txt") == "a\nb\nc\n")
    }

    // MARK: >> (append)

    @Test func appendAddsToEnd() async throws {
        let (_, dir) = makeShell(); defer { cleanup(dir) }
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = dir
        try await cap.shell.run("echo one > log.txt")
        try await cap.shell.run("echo two >> log.txt")
        try await cap.shell.run("echo three >> log.txt")
        #expect(readFile("\(dir)/log.txt") == "one\ntwo\nthree\n")
    }

    @Test func appendCreatesIfMissing() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo created >> new.txt")
        #expect(readFile("\(dir)/new.txt") == "created\n")
    }

    // MARK: Stderr redirection

    @Test func stderrRedirectToFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        cap.shell.register(name: "warn") { _ in
            Shell.current.stdout("out\n")
            Shell.current.stderr("err\n")
            return .success
        }
        try await cap.shell.run("warn 2> err.txt")
        #expect(cap.stdout == "out\n",
                "stdout passes through unchanged")
        #expect(cap.stderr == "",
                "stderr must go to the file, not through")
        #expect(readFile("\(dir)/err.txt") == "err\n")
    }

    // MARK: 2>&1

    @Test func stderrToStdoutSameFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        cap.shell.register(name: "noisy") { _ in
            Shell.current.stdout("out\n")
            Shell.current.stderr("err\n")
            return .success
        }
        // Order matters: `>out 2>&1` → both into out.txt.
        try await cap.shell.run("noisy > out.txt 2>&1")
        let contents = readFile("\(dir)/out.txt")
        #expect(contents.contains("out\n"))
        #expect(contents.contains("err\n"))
        #expect(cap.stdout == "")
        #expect(cap.stderr == "")
    }

    @Test func stderrToStdoutReversedOrderDiffers() async throws {
        // `2>&1 > out.txt` dups stderr to stdout BEFORE redirecting
        // stdout → so stderr still points at the caller's stdout.
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        cap.shell.register(name: "noisy") { _ in
            Shell.current.stdout("out\n")
            Shell.current.stderr("err\n")
            return .success
        }
        try await cap.shell.run("noisy 2>&1 > out.txt")
        #expect(readFile("\(dir)/out.txt") == "out\n")
        // stderr was pointed at caller's stdout before the file
        // redirect, so "err\n" goes to the captured stdout.
        #expect(cap.stdout == "err\n")
    }

    @Test func stdoutToStderr() async throws {
        let (cap, _) = makeShell()
        cap.shell.register(name: "mixed") { _ in
            Shell.current.stdout("out\n")
            return .success
        }
        try await cap.shell.run("mixed 1>&2")
        #expect(cap.stdout == "")
        #expect(cap.stderr == "out\n")
    }

    // MARK: < (stdin from file)

    @Test func stdinFromFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try "line1\nline2\n".write(
            toFile: "\(dir)/in.txt", atomically: true, encoding: .utf8)
        cap.shell.register(name: "count") { _ in
            var n = 0
            for await _ in Shell.current.stdin.lines { n += 1 }
            Shell.current.stdout("\(n)\n")
            return .success
        }
        try await cap.shell.run("count < in.txt")
        #expect(cap.stdout == "2\n")
    }

    @Test func stdinFromMissingFileFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        await #expect(throws: (any Error).self) {
            try await cap.shell.run("cat < nope.txt")
        }
        _ = cap
    }

    // MARK: heredoc

    @Test func heredocBecomesStdin() async throws {
        let (cap, _) = makeShell()
        cap.shell.register(name: "capture") { _ in
            let s = await Shell.current.stdin.readAllString()
            Shell.current.stdout("[\(s)]")
            return .success
        }
        try await cap.shell.run("""
            capture <<EOF
            line1
            line2
            EOF
            """)
        #expect(cap.stdout == "[line1\nline2\n]")
    }

    @Test func unquotedHeredocExpandsVariables() async throws {
        let (cap, _) = makeShell()
        cap.shell.environment["NAME"] = "oliver"
        cap.shell.register(name: "capture") { _ in
            let s = await Shell.current.stdin.readAllString()
            Shell.current.stdout(s)
            return .success
        }
        try await cap.shell.run("""
            capture <<END
            hi $NAME
            END
            """)
        #expect(cap.stdout == "hi oliver\n",
                "<<END (unquoted delimiter) expands $NAME, matching bash")
    }

    @Test func quotedHeredocStaysLiteral() async throws {
        let (cap, _) = makeShell()
        cap.shell.environment["NAME"] = "oliver"
        cap.shell.register(name: "capture") { _ in
            let s = await Shell.current.stdin.readAllString()
            Shell.current.stdout(s)
            return .success
        }
        try await cap.shell.run("""
            capture <<'END'
            hi $NAME
            END
            """)
        #expect(cap.stdout == "hi $NAME\n",
                "<<'END' suppresses expansion, body is literal")
    }

    // MARK: Redirect + pipeline

    @Test func redirectInsidePipeline() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        cap.shell.register(name: "emit") { _ in
            Shell.current.stdout("one\ntwo\nthree\n")
            return .success
        }
        cap.shell.register(name: "upper") { _ in
            let s = await Shell.current.stdin.readAllString()
            Shell.current.stdout(s.uppercased())
            return .success
        }
        try await cap.shell.run("emit | upper > out.txt")
        #expect(readFile("\(dir)/out.txt") == "ONE\nTWO\nTHREE\n")
        #expect(cap.stdout == "")
    }

    // MARK: Compound redirect

    @Test func redirectOnForLoop() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("""
            for x in a b c; do
              echo $x
            done > letters.txt
            """)
        #expect(readFile("\(dir)/letters.txt") == "a\nb\nc\n")
        #expect(cap.stdout == "",
                "the whole loop's output is redirected, none escapes")
    }

    @Test func redirectOnGroup() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("{ echo a; echo b; } > out.txt")
        #expect(readFile("\(dir)/out.txt") == "a\nb\n")
        #expect(cap.stdout == "")
    }

    @Test func redirectOnIf() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("""
            if true; then
              echo yes
            fi > out.txt
            """)
        #expect(readFile("\(dir)/out.txt") == "yes\n")
    }

    // MARK: Failure cleanup

    @Test func noRedirectLeakAfterCommand() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo first > out.txt")
        try await cap.shell.run("echo second")
        // The second `echo` without redirect must reach stdout, proving
        // the previous redirect's sink was restored.
        #expect(cap.stdout == "second\n")
        #expect(readFile("\(dir)/out.txt") == "first\n")
    }

    @Test func redirectRestoresOnCommandFailure() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        _ = try? await cap.shell.run("nosuchcommand > out.txt")
        try await cap.shell.run("echo after")
        #expect(cap.stdout == "after\n",
                "stdout restored even after failing command")
    }

    // MARK: Assignments + redirect only

    @Test func standaloneRedirectCreatesEmptyFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("> empty.txt")
        #expect(FileManager.default.fileExists(atPath: "\(dir)/empty.txt"))
        #expect(readFile("\(dir)/empty.txt") == "")
        _ = cap
    }

    // MARK: Variable-based target

    @Test func redirectTargetCanBeVariable() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        cap.shell.environment["LOG"] = "log.txt"
        try await cap.shell.run("echo hi > $LOG")
        #expect(readFile("\(dir)/log.txt") == "hi\n")
    }

    #if !os(Windows)
    @Test func redirectTargetCanUseTilde() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        cap.shell.environment["HOME"] = dir
        try await cap.shell.run("echo hi > ~/greeting.txt")
        #expect(readFile("\(dir)/greeting.txt") == "hi\n")
    }
    #endif
}
