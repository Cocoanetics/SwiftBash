import Testing
import Foundation
@testable import BashInterpreter

@Suite struct CwdFlagTests {

    // MARK: pwd -L / -P

    @Test func pwdDefaultIsLogical() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/var"
        try await cap.shell.run("pwd")
        #expect(cap.stdout == "/var\n")
    }

    @Test func pwdDashLPrintsLogical() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/var"
        try await cap.shell.run("pwd -L")
        #expect(cap.stdout == "/var\n")
    }

    @Test func pwdDashPResolvesUserSymlink() async throws {
        // Plant a real-fs symlink and verify -P resolves through it.
        // (System symlinks like /var → /private/var are hidden from
        // Foundation's URL canonicalisation by macOS convention; this
        // test covers the user-created case which is what scripts
        // actually rely on.)
        let dir = NSTemporaryDirectory() + "pwd-P-\(UUID())"
        let real = dir + "/real"
        let link = dir + "/link"
        try FileManager.default.createDirectory(
            atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: real)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = link
        try await cap.shell.run("pwd")
        #expect(cap.stdout == "\(link)\n")

        let cap2 = CapturingShell()
        cap2.shell.environment.workingDirectory = link
        try await cap2.shell.run("pwd -P")
        #expect(cap2.stdout == "\(real)\n")
    }

    @Test func pwdLastFlagWins() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/usr/bin"
        try await cap.shell.run("pwd -P -L")
        #expect(cap.stdout == "/usr/bin\n")
    }

    @Test func pwdRejectsUnknownFlag() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("pwd -X")
        #expect(status.code == 2)
        #expect(cap.stderr.contains("invalid option"))
    }

    // MARK: cd -L / -P

    @Test func cdDashPCanonicalizesAtChdirTime() async throws {
        // Plant a user symlink so the test doesn't depend on system
        // symlinks like /var (which Foundation hides under macOS).
        let dir = NSTemporaryDirectory() + "cd-P-\(UUID())"
        let real = dir + "/real"
        let link = dir + "/link"
        try FileManager.default.createDirectory(
            atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: real)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let cap = CapturingShell()
        try await cap.shell.run("cd -P \(link)")
        #expect(cap.shell.environment["PWD"] == real)
        #expect(cap.shell.environment.workingDirectory == real)
    }

    @Test func cdDashLDefaultPreservesSymlinkPath() async throws {
        let dir = NSTemporaryDirectory() + "cd-L-\(UUID())"
        let real = dir + "/real"
        let link = dir + "/link"
        try FileManager.default.createDirectory(
            atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: real)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let cap = CapturingShell()
        try await cap.shell.run("cd \(link)")
        #expect(cap.shell.environment["PWD"] == link)
        #expect(cap.shell.environment.workingDirectory == link)
    }

    @Test func cdDashLAndPSwitchable() async throws {
        let dir = NSTemporaryDirectory() + "cd-L-P-\(UUID())"
        let real = dir + "/real"
        let link = dir + "/link"
        try FileManager.default.createDirectory(
            atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: real)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let cap = CapturingShell()
        try await cap.shell.run("cd -P -L \(link)")
        // Last flag wins → -L → keep symlink path verbatim.
        #expect(cap.shell.environment.workingDirectory == link)
    }

    @Test func cdRejectsUnknownFlag() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("cd -Q /tmp")
        #expect(status.code == 2)
        #expect(cap.stderr.contains("invalid option"))
    }

    @Test func cdDashAfterFlagsStillWorks() async throws {
        // `cd -L -` should switch to OLDPWD (the `-` is a path arg,
        // not a flag, since it follows `--`-style intent of "stop
        // flag parsing").
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"
        cap.shell.environment["OLDPWD"] = "/tmp"
        try await cap.shell.run("cd -L -")
        #expect(cap.shell.environment.workingDirectory == "/tmp")
    }

    @Test func cdMinusPrintsDestination() async throws {
        // bash prints the destination when you `cd -`, matching the
        // spec but not when you `cd <path>`.
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/"
        cap.shell.environment["OLDPWD"] = "/tmp"
        try await cap.shell.run("cd -")
        #expect(cap.stdout == "/tmp\n")
    }

    @Test func cdNoOldpwdErrors() async throws {
        let cap = CapturingShell()
        cap.shell.environment["OLDPWD"] = nil
        let status = try await cap.shell.run("cd -")
        #expect(status == .failure)
        #expect(cap.stderr.contains("OLDPWD not set"))
    }

    // MARK: sandbox HOME-as-workspace

    #if !os(Windows)
    @Test func sandboxedShellHomeMatchesWorkspaceWhenConfiguredThatWay() async throws {
        // Mirrors the CLI's --sandbox setup: HOME points at the
        // workspace, so `cd` (no arg) and `~` both land there.
        let dir = NSTemporaryDirectory() + "sandbox-home-\(UUID())"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let fs = try SandboxedOverlayFileSystem(.init(
            root: dir, mountPoint: "/batch"))
        var env = Environment.synthetic(workingDirectory: "/batch")
        env["HOME"] = "/batch"
        let cap = CapturingShell(environment: env)
        cap.shell.fileSystem = fs

        try await cap.shell.run(#"""
            cd /
            cd
            echo "after-cd: $(pwd)"
            cd /
            echo tilde: ~
            """#)
        #expect(cap.stdout.contains("after-cd: /batch"))
        // Tilde expands only when *unquoted* — that's what most
        // scripts type. Inside `"…"` it would stay literal.
        #expect(cap.stdout.contains("tilde: /batch"))
    }
    #endif
}
