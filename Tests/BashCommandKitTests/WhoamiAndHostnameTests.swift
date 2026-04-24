import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct WhoamiAndHostnameTests {

    // MARK: whoami

    @Test func whoamiPrintsNonEmpty() async throws {
        let cap = CapturingShell()
        cap.shell.register(WhoamiCommand.self)
        try await cap.shell.run("whoami")
        let name = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!name.isEmpty)
        #expect(name == ProcessInfo.processInfo.userName)
    }

    @Test func whoamiUsableInCommandSubstitution() async throws {
        let cap = CapturingShell()
        cap.shell.register(WhoamiCommand.self)
        try await cap.shell.run(#"U=$(whoami); echo "hello $U""#)
        #expect(cap.stdout.hasPrefix("hello "), "\(cap.stdout)")
    }

    // MARK: hostname

    @Test func hostnamePrintsNonEmpty() async throws {
        let cap = CapturingShell()
        cap.shell.register(HostnameCommand.self)
        try await cap.shell.run("hostname")
        let host = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!host.isEmpty)
        #expect(host == ProcessInfo.processInfo.hostName)
    }
}
