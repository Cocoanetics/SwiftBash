import Testing
import Foundation
import ShellKit
@testable import BashInterpreter
@testable import BashSwiftScript

/// Issue #37: in-process `swift` / `swift-script` must accept the
/// same argv shape as the standalone CLI — `--version`, `-e <expr>`,
/// and `<script.swift>`. Before the fix these names were only
/// registered as `ScriptInterpreter`s (for `#!/usr/bin/env`
/// shebangs), so a bare `swift --version` invocation failed.
@Suite(.timeLimit(.minutes(1))) struct SwiftScriptCommandSurfaceTests {

    private func makeShell() -> (BashInterpreter.Shell, TestCapture) {
        let capture = TestCapture()
        let shell = BashInterpreter.Shell(
            stdout: capture.stdoutSink,
            stderr: capture.stderrSink,
            environment: Environment(),
            commands: BashInterpreter.Shell.defaultCommands())
        shell.registerSwiftScript()
        return (shell, capture)
    }

    private static func bashQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @Test func swiftVersionFlagRunsInProcess() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("swift --version")
        #expect(status.code == 0)
        #expect(cap.stdout.contains("swift-script"))
    }

    @Test func swiftScriptVersionFlagRunsInProcess() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("swift-script --version")
        #expect(status.code == 0)
        #expect(cap.stdout.contains("swift-script"))
    }

    @Test func swiftDashEEvaluatesExpression() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("swift -e 'print(2 + 3)'")
        #expect(status.code == 0)
        #expect(cap.stdout == "5\n")
    }

    @Test func swiftDashENoExpressionReportsUsage() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("swift -e")
        #expect(status.code == 2)
        #expect(cap.stderr.contains("usage:"))
    }

    @Test func swiftWithScriptPathStillWorks() async throws {
        // The command path should also handle a script-file invocation
        // (no shebang) — `swift script.swift` with no `#!` line.
        let (shell, cap) = makeShell()
        let dir = NSTemporaryDirectory()
            + "swift-script-cmd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/script.swift"
        try "print(\"hi from file\")\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path)

        let status = try await shell.run("swift \(Self.bashQuote(path))")
        #expect(status.code == 0)
        #expect(cap.stdout == "hi from file\n")
    }
}
