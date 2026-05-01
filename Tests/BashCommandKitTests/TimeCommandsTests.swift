import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct TimeCommandsTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func timeRunsCommandAndReports() async throws {
        let cap = makeShell()
        // `time` is a bash reserved word; escape with backslash to
        // dispatch to our command instead of the keyword handler.
        let status = try await cap.shell.run(#"\time echo hello"#)
        #expect(status == .success)
        #expect(cap.stdout == "hello\n")
        #expect(cap.stderr.contains("real"))
        #expect(cap.stderr.contains("user"))
        #expect(cap.stderr.contains("sys"))
    }

    @Test func timePropagatesExitStatus() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run(#"\time false"#)
        #expect(status == .failure)
    }

    @Test func timeoutAllowsFastCommand() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("timeout 5 echo ok")
        #expect(status == .success)
        #expect(cap.stdout == "ok\n")
    }

    @Test func timeoutKillsSlowCommand() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("timeout 0.05 sleep 5")
        #expect(status == ExitStatus(124))
        #expect(cap.stderr.contains("timed out"))
    }

    @Test func timeoutDurationSuffixes() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("timeout 1s echo ok")
        #expect(status == .success)
    }
}
