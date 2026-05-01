import Testing
import Foundation
@testable import BashInterpreter

/// Routing layer for the four `/dev/...` standard entries that don't
/// exist in a sandboxed `FileSystem` but are commonly used in scripts:
/// `/dev/null`, `/dev/stdin`, `/dev/stdout`, `/dev/stderr`. Tested
/// against `InMemoryFileSystem` so any pass means we're not relying on
/// the host kernel having actual `/dev` entries.
#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct DevPathTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        return cap
    }

    // MARK: openOutputPath

    @Test func devNullDiscardsWrites() async throws {
        let cap = makeShell()
        let sink = try await cap.shell.openOutputPath("/dev/null")
        sink.write("anything")
        sink.finish()
        // No error, nothing landed anywhere observable.
        #expect(cap.stdout == "")
        #expect(cap.stderr == "")
    }

    @Test func devStdoutForwardsToShellStdout() async throws {
        let cap = makeShell()
        let sink = try await cap.shell.openOutputPath("/dev/stdout")
        sink.write("hello\n")
        sink.finish()  // must NOT close the shell's real stdout
        // Real stdout still works after the redirection unwinds.
        cap.shell.stdout("after\n")
        #expect(cap.stdout == "hello\nafter\n")
    }

    @Test func devStderrForwardsToShellStderr() async throws {
        let cap = makeShell()
        let sink = try await cap.shell.openOutputPath("/dev/stderr")
        sink.write("oops\n")
        sink.finish()
        cap.shell.stderr("after\n")
        #expect(cap.stderr == "oops\nafter\n")
    }

    @Test func writingToStdinIsAnError() async throws {
        let cap = makeShell()
        do {
            _ = try await cap.shell.openOutputPath("/dev/stdin")
            #expect(Bool(false), "expected permissionDenied")
        } catch FileSystemError.permissionDenied {
            // expected
        }
    }

    // MARK: openInputPath

    @Test func devNullReadIsEmpty() async throws {
        let cap = makeShell()
        let src = try await cap.shell.openInputPath("/dev/null")
        let data = await src.readAllData()
        #expect(data.isEmpty)
    }

    @Test func devStdinReadsFromShellStdin() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("piped-in\n")
        let src = try await cap.shell.openInputPath("/dev/stdin")
        let text = await src.readAllString()
        #expect(text == "piped-in\n")
    }

    // MARK: convenience read/write

    @Test func readDataAtDevNullIsEmpty() async throws {
        let cap = makeShell()
        let data = try await cap.shell.readDataAtPath("/dev/null")
        #expect(data.isEmpty)
    }

    @Test func writeDataToDevNullDiscards() async throws {
        let cap = makeShell()
        try await cap.shell.writeData(
            Data("nope".utf8), toPath: "/dev/null")
        // No exception; no observable side effect.
        #expect(cap.stdout == "")
    }

    @Test func writeDataToDevStdoutWrites() async throws {
        let cap = makeShell()
        try await cap.shell.writeData(
            Data("hi\n".utf8), toPath: "/dev/stdout")
        #expect(cap.stdout == "hi\n")
    }

    // MARK: metadataAtPath

    @Test func metadataAtDevPathsExists() async throws {
        let cap = makeShell()
        for path in [
            "/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr"
        ] {
            let meta = try await cap.shell.metadataAtPath(path)
            #expect(meta != nil, "expected metadata for \(path)")
        }
    }

    // MARK: end-to-end through redirection

    @Test func redirectStdoutToDevNullSilencesOutput() async throws {
        let cap = makeShell()
        cap.shell.commands["echo"] = EchoCommand()
        try await cap.shell.run("echo loud > /dev/null")
        #expect(cap.stdout == "")
    }

    @Test func redirectStdoutToDevStdoutPrintsNormally() async throws {
        let cap = makeShell()
        cap.shell.commands["echo"] = EchoCommand()
        try await cap.shell.run("echo hi > /dev/stdout")
        #expect(cap.stdout == "hi\n")
    }

    @Test func redirectStdinFromDevNull() async throws {
        let cap = makeShell()
        cap.shell.commands["echo"] = EchoCommand()
        // Redirecting stdin from /dev/null effectively gives an empty
        // input. Nothing should crash; echo doesn't read stdin anyway.
        try await cap.shell.run("echo done < /dev/null")
        #expect(cap.stdout == "done\n")
    }
}
#endif
