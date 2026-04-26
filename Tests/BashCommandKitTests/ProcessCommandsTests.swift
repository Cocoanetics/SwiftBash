import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct ProcessCommandsTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func psListsCurrent() async throws {
        let cap = makeShell()
        try await cap.shell.run("ps")
        #expect(cap.stdout.contains("PID"))
        // Our own pid should be present.
        #expect(cap.stdout.contains("\(getpid())"))
    }

    @Test func psFilterByPid() async throws {
        let cap = makeShell()
        try await cap.shell.run("ps -p \(getpid())")
        #expect(cap.stdout.contains("\(getpid())"))
    }

    @Test func psCustomColumns() async throws {
        let cap = makeShell()
        try await cap.shell.run("ps -o pid,ppid")
        #expect(cap.stdout.contains("PID"))
        #expect(cap.stdout.contains("PPID"))
    }

    @Test func killInvalidPid() async throws {
        let cap = makeShell()
        // PID 999999 almost certainly doesn't exist.
        let status = try await cap.shell.run("kill 999999")
        #expect(status == .failure)
        #expect(cap.stderr.contains("kill"))
    }

    @Test func killSignalParsing() async throws {
        let cap = makeShell()
        // Use kill -0 (no signal sent, just check existence) on our own pid.
        let status = try await cap.shell.run("kill -0 \(getpid())")
        #expect(status == .success)
    }

    @Test func killListsSignals() async throws {
        let cap = makeShell()
        try await cap.shell.run("kill -l")
        #expect(cap.stdout.contains("HUP"))
        #expect(cap.stdout.contains("TERM"))
    }

    @Test func pgrepFindsSelf() async throws {
        let cap = makeShell()
        // Our own process name might be "swift-bash" or "xctest" depending
        // on the test runner — just check the command produces output.
        try await cap.shell.run("pgrep .")
        #expect(cap.stdout.split(separator: "\n").count > 0)
    }

    @Test func pgrepNoMatch() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("pgrep zzzzzz_definitely_not_a_process")
        #expect(status == ExitStatus(1))
    }
}
