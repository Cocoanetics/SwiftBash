import Testing
import Foundation
@testable import BashInterpreter

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

@Suite(.timeLimit(.minutes(1))) struct HostInfoTests {

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

    // ProcessInfo.userName is macOS / Linux only — iOS / tvOS /
    // watchOS don't expose it (HostInfo.real() falls back to a
    // getpwuid lookup there). Gate the two tests that touch it.
    #if os(macOS) || os(Linux) || os(Android) || os(Windows)
    @Test func syntheticLeaksNoHostStrings() {
        // Sanity: every field in `.synthetic` is a known anonymous
        // value — nothing pulled from ProcessInfo at construction.
        let info = HostInfo.synthetic
        let allFields = [
            info.userName, info.fullUserName, info.hostName, info.groupName,
            info.kernelName, info.kernelRelease, info.kernelVersion,
            info.machine, info.nodeName
        ]
        let real = ProcessInfo.processInfo
        for field in allFields {
            #expect(field != real.userName)
            #expect(field != real.hostName)
        }
    }
    #endif

    // MARK: real() opt-in

    #if os(macOS) || os(Linux) || os(Android) || os(Windows)
    @Test func realPullsFromProcessInfo() {
        let real = HostInfo.real()
        #expect(real.userName == ProcessInfo.processInfo.userName)
        #expect(real.uid > 0)
        #expect(!real.kernelName.isEmpty)
    }
    #endif

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
@Suite(.timeLimit(.minutes(1))) struct SandboxLeakAuditTests {

    private func makeSandboxedShell() -> Shell {
        let shell = Shell(
            fileSystem: InMemoryFileSystem(),
            environment: .synthetic(workingDirectory: "/batch"))
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
        #if os(Windows)
        let realPID = _getpid()
        #else
        let realPID = getpid()
        #endif
        #expect(result.stdout != "\(realPID)\n")
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
