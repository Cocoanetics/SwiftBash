import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct WhoamiAndHostnameTests {

    // MARK: whoami — synthetic by default

    @Test func whoamiSyntheticByDefault() async throws {
        let cap = CapturingShell()
        cap.shell.install(WhoamiCommand.self)
        try await cap.shell.run("whoami")
        let name = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Default `Shell.hostInfo` is `.synthetic`; the real host's
        // user name is never queried.
        #expect(name == HostInfo.synthetic.userName)
        #expect(name == "user")
    }

    @Test func whoamiCustomHostInfo() async throws {
        let cap = CapturingShell()
        cap.shell.install(WhoamiCommand.self)
        cap.shell.hostInfo.userName = "alice"
        try await cap.shell.run("whoami")
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "alice")
    }

    @Test func whoamiUsableInCommandSubstitution() async throws {
        let cap = CapturingShell()
        cap.shell.install(WhoamiCommand.self)
        try await cap.shell.run(#"U=$(whoami); echo "hello $U""#)
        #expect(cap.stdout == "hello user\n")
    }

    // MARK: hostname — synthetic by default

    @Test func hostnameSyntheticByDefault() async throws {
        let cap = CapturingShell()
        cap.shell.install(HostnameCommand.self)
        try await cap.shell.run("hostname")
        let host = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(host == HostInfo.synthetic.hostName)
        #expect(host == "sandbox")
    }

    @Test func hostnameCustomHostInfo() async throws {
        let cap = CapturingShell()
        cap.shell.install(HostnameCommand.self)
        cap.shell.hostInfo.hostName = "myhost"
        try await cap.shell.run("hostname")
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "myhost")
    }

    // MARK: HostInfo.real() opt-in

    // ProcessInfo.userName is unavailable on iOS / tvOS / watchOS;
    // HostInfo.real() falls back to a getpwuid lookup there. Gate the
    // two tests that compare against ProcessInfo directly.
    #if os(macOS) || os(Linux) || os(Android) || os(Windows)
    @Test func realHostInfoMatchesProcessInfo() async throws {
        let real = HostInfo.real()
        // Sanity: `.real()` does query the host.
        #expect(real.userName == ProcessInfo.processInfo.userName)
        #expect(!real.hostName.isEmpty)
        #expect(real.uid > 0)
    }

    @Test func realHostInfoFlowsToWhoami() async throws {
        let cap = CapturingShell()
        cap.shell.install(WhoamiCommand.self)
        cap.shell.hostInfo = .real()
        try await cap.shell.run("whoami")
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == ProcessInfo.processInfo.userName)
    }
    #endif
}
