import XCTest
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

final class SleepCommandTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(SleepCommand.self)
        return cap
    }

    func testSleepActuallyWaits() async throws {
        let cap = makeShell()
        let start = Date()
        try await cap.shell.run("sleep 0.05")   // 50 ms
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.04)
    }

    func testZeroIsImmediateSuccess() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("sleep 0")
        XCTAssertEqual(status, .success)
    }

    func testNegativeFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("sleep -0.1")
        XCTAssertFalse(status.isSuccess)
    }

    func testNonNumericFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("sleep abc")
        XCTAssertFalse(status.isSuccess)
    }
}
