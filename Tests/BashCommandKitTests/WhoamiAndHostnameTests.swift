import XCTest
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

final class WhoamiAndHostnameTests: XCTestCase {

    // MARK: whoami

    func testWhoamiPrintsNonEmpty() async throws {
        let cap = CapturingShell()
        cap.shell.register(WhoamiCommand.self)
        try await cap.shell.run("whoami")
        let name = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(name.isEmpty)
        XCTAssertEqual(name, ProcessInfo.processInfo.userName)
    }

    func testWhoamiUsableInCommandSubstitution() async throws {
        let cap = CapturingShell()
        cap.shell.register(WhoamiCommand.self)
        try await cap.shell.run(#"U=$(whoami); echo "hello $U""#)
        XCTAssertTrue(cap.stdout.hasPrefix("hello "), cap.stdout)
    }

    // MARK: hostname

    func testHostnamePrintsNonEmpty() async throws {
        let cap = CapturingShell()
        cap.shell.register(HostnameCommand.self)
        try await cap.shell.run("hostname")
        let host = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(host.isEmpty)
        XCTAssertEqual(host, ProcessInfo.processInfo.hostName)
    }
}
