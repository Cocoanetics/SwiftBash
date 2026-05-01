import Testing
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct ListExecutionTests {

    @Test func semicolonRunsBoth() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo a; echo b")
        #expect(cap.stdout == "a\nb\n")
    }

    @Test func andAndShortCircuitsOnFailure() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("false && echo nope")
        #expect(cap.stdout == "")
    }

    @Test func andAndContinuesOnSuccess() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("true && echo yes")
        #expect(cap.stdout == "yes\n")
    }

    @Test func orOrShortCircuitsOnSuccess() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("true || echo nope")
        #expect(cap.stdout == "")
    }

    @Test func orOrFiresOnFailure() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("false || echo fallback")
        #expect(cap.stdout == "fallback\n")
    }

    @Test func multipleLinesRunInOrder() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo one\necho two\necho three")
        #expect(cap.stdout == "one\ntwo\nthree\n")
    }

    @Test func exitStatusPropagates() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("true; false")
        #expect(status == .failure)
    }
}
#endif
