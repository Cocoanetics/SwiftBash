import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct SleepCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(SleepCommand.self)
        return cap
    }

    @Test func sleepActuallyWaits() async throws {
        let cap = makeShell()
        let start = Date()
        try await cap.shell.run("sleep 0.05")   // 50 ms
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.04)
    }

    @Test func zeroIsImmediateSuccess() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("sleep 0")
        #expect(status == .success)
    }

    @Test func negativeFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("sleep -0.1")
        #expect(!status.isSuccess)
    }

    @Test func nonNumericFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("sleep abc")
        #expect(!status.isSuccess)
    }
}
