import Testing
@testable import BashInterpreter

@Suite struct ShellTests {

    // MARK: Basic smoke

    @Test func echoHelloWorld() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("echo hello world")
        #expect(status == .success)
        #expect(cap.stdout == "hello world\n")
    }

    @Test func emptyInputIsSuccess() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("")
        #expect(status == .success)
        #expect(cap.stdout == "")
    }

    @Test func commandNotFoundThrows() async {
        let cap = CapturingShell()
        let err = await #expect(throws: BashInterpreterError.self) {
            try await cap.shell.run("nosuchcommand")
        }
        guard case .commandNotFound(let name) = err else {
            Issue.record("expected commandNotFound, got \(String(describing: err))")
            return
        }
        #expect(name == "nosuchcommand")
    }

    @Test func lastExitStatusTracksCommands() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("true")
        #expect(cap.shell.lastExitStatus == .success)
        try await cap.shell.run("false")
        #expect(cap.shell.lastExitStatus == .failure)
    }
}
