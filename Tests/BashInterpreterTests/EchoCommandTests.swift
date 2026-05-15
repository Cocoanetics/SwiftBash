import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct EchoCommandTests {

    private func makeShell() -> (Shell, OutputSink) {
        let outBox = StringBox()
        let stdout = OutputSink { data in
            outBox.append(String(bytes: data, encoding: .utf8) ?? "")
        }
        let shell = Shell(stdout: stdout, stderr: .discard)
        return (shell, stdout)
    }

    private func captured(_ box: StringBox) -> String { box.read() }

    @Test func defaultAppendsNewline() async throws {
        let (shell, _) = makeShell()
        let cap = StringBox()
        shell.stdout = OutputSink { data in cap.append(String(bytes: data, encoding: .utf8) ?? "") }
        try await shell.run("echo hello world")
        #expect(captured(cap) == "hello world\n")
    }

    @Test func dashNSuppressesNewline() async throws {
        let shell = Shell(stderr: .discard)
        let cap = StringBox()
        shell.stdout = OutputSink { data in cap.append(String(bytes: data, encoding: .utf8) ?? "") }
        try await shell.run("echo -n hello")
        #expect(captured(cap) == "hello")
    }

    @Test func dashEInterpretsTabAndNewline() async throws {
        let shell = Shell(stderr: .discard)
        let cap = StringBox()
        shell.stdout = OutputSink { data in cap.append(String(bytes: data, encoding: .utf8) ?? "") }
        try await shell.run(#"echo -e "a\tb\nc""#)
        #expect(captured(cap) == "a\tb\nc\n")
    }

    @Test func dashEhexEscape() async throws {
        let shell = Shell(stderr: .discard)
        let cap = StringBox()
        shell.stdout = OutputSink { data in cap.append(String(bytes: data, encoding: .utf8) ?? "") }
        try await shell.run(#"echo -e "\x41\x42""#)
        #expect(captured(cap) == "AB\n")
    }

    @Test func dashEoctalEscape() async throws {
        let shell = Shell(stderr: .discard)
        let cap = StringBox()
        shell.stdout = OutputSink { data in cap.append(String(bytes: data, encoding: .utf8) ?? "") }
        try await shell.run(#"echo -e "\0101\0102""#)
        #expect(captured(cap) == "AB\n")
    }

    @Test func dashEbackslashC() async throws {
        let shell = Shell(stderr: .discard)
        let cap = StringBox()
        shell.stdout = OutputSink { data in cap.append(String(bytes: data, encoding: .utf8) ?? "") }
        try await shell.run(#"echo -e "abc\cdef""#)
        // \c halts output and suppresses the newline.
        #expect(captured(cap) == "abc")
    }

    @Test func dashEEdisablesEscapes() async throws {
        let shell = Shell(stderr: .discard)
        let cap = StringBox()
        shell.stdout = OutputSink { data in cap.append(String(bytes: data, encoding: .utf8) ?? "") }
        try await shell.run(#"echo -E "a\tb""#)
        #expect(captured(cap) == "a\\tb\n")
    }

    @Test func combinedFlags() async throws {
        let shell = Shell(stderr: .discard)
        let cap = StringBox()
        shell.stdout = OutputSink { data in cap.append(String(bytes: data, encoding: .utf8) ?? "") }
        try await shell.run(#"echo -ne "a\tb""#)
        #expect(captured(cap) == "a\tb")
    }
}

private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ string: String) { lock.lock(); defer { lock.unlock() }; value += string }
    func read() -> String { lock.lock(); defer { lock.unlock() }; return value }
}
