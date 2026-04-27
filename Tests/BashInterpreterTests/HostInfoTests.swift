import Testing
import Foundation
@testable import BashInterpreter

@Suite struct HostInfoTests {

    // MARK: synthetic defaults

    @Test func defaultIsSynthetic() {
        let shell = Shell()
        #expect(shell.hostInfo == .synthetic)
        #expect(shell.hostInfo.userName == "user")
        #expect(shell.hostInfo.hostName == "sandbox")
        #expect(shell.hostInfo.uid == 1000)
        #expect(shell.hostInfo.gid == 1000)
        #expect(shell.hostInfo.kernelName == "Darwin")
        #expect(shell.hostInfo.machine == "arm64")
    }

    @Test func syntheticLeaksNoHostStrings() {
        // Sanity: every field in `.synthetic` is a known anonymous
        // value — nothing pulled from ProcessInfo at construction.
        let s = HostInfo.synthetic
        let allFields = [
            s.userName, s.fullUserName, s.hostName, s.groupName,
            s.kernelName, s.kernelRelease, s.kernelVersion,
            s.machine, s.nodeName,
        ]
        let real = ProcessInfo.processInfo
        for field in allFields {
            #expect(field != real.userName)
            #expect(field != real.hostName)
        }
    }

    // MARK: real() opt-in

    @Test func realPullsFromProcessInfo() {
        let real = HostInfo.real()
        #expect(real.userName == ProcessInfo.processInfo.userName)
        #expect(real.uid > 0)
        #expect(!real.kernelName.isEmpty)
    }

    // MARK: copy() inheritance

    @Test func copyInheritsHostInfo() {
        let parent = Shell()
        parent.hostInfo.userName = "alice"
        parent.hostInfo.hostName = "parent-host"
        let child = parent.copy()
        #expect(child.hostInfo.userName == "alice")
        #expect(child.hostInfo.hostName == "parent-host")
    }

    @Test func childMutationsDoNotLeak() {
        let parent = Shell()
        parent.hostInfo.userName = "alice"
        let child = parent.copy()
        child.hostInfo.userName = "bob"
        #expect(parent.hostInfo.userName == "alice")
        #expect(child.hostInfo.userName == "bob")
    }
}

/// Comprehensive sandbox-leak verification — runs scripts that try to
/// observe the host through every channel SwiftBash currently exposes,
/// and asserts the synthetic values come back instead.
@Suite struct SandboxLeakAuditTests {

    private func makeSandboxedShell() -> Shell {
        let shell = Shell(
            environment: .synthetic(workingDirectory: "/batch"),
            fileSystem: InMemoryFileSystem())
        shell.hostInfo = .synthetic
        // Register the standard commands without triggering import-cycle
        // — we only need the identity ones for this audit.
        return shell
    }

    @Test func dollarDollarDoesNotLeakRealPID() async throws {
        let shell = makeSandboxedShell()
        let result = try await shell.runCapturing("echo $$")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "1")
        #expect(result.stdout != "\(getpid())\n")
    }

    @Test func unsetEnvVarDoesNotLeak() async throws {
        // The synthetic env doesn't include the host's
        // process-environment, so a script reading $SECRET_VAR sees
        // empty even if the host has it set.
        let shell = makeSandboxedShell()
        let result = try await shell.runCapturing(
            #"echo "X=$THISVARSURELYNOTSET""#)
        #expect(result.stdout == "X=\n")
    }
}
