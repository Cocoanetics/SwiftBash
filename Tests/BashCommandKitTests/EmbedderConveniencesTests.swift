import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Conveniences added for SwiftBash embedders building interactive
/// shells (iBash, swift-bash --interactive, similar). Each one used
/// to require a closure or a regex on the embedder side; these tests
/// pin the new public surface.
@Suite("Embedder conveniences")
struct EmbedderConveniencesTests {

    @Test("registerBashShebang lets ./script.sh dispatch via #!bash")
    func bashShebangRoutesScript() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-shebang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("greet.sh")
        try "#!/usr/bin/env bash\necho hello $1\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: script.path)

        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.registerBashShebang()
        cap.shell.environment.workingDirectory = dir.path

        let status = try await cap.shell.run("./greet.sh world")
        #expect(status == .success)
        #expect(cap.stdout.contains("hello world"))
    }

    @Test("interactive shell suppresses `: line N:` in error prefix")
    func interactiveErrorFormat() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.registerBashShebang()
        cap.shell.scriptName = "iBash"
        cap.shell.interactive = true

        // Trigger a "command not found" — that's the easiest path
        // through `errorLocationPrefix()`.
        let status = try await cap.shell.run("nonexistent_command_xyz")
        #expect(!status.isSuccess)
        #expect(cap.stderr.contains("iBash: nonexistent_command_xyz"))
        #expect(!cap.stderr.contains("line 1:"))
    }

    @Test("non-interactive (default) keeps the line-N prefix")
    func nonInteractiveErrorFormat() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.scriptName = "myscript"
        // interactive defaults to false

        let status = try await cap.shell.run("nonexistent_command_xyz")
        #expect(!status.isSuccess)
        #expect(cap.stderr.contains("myscript: line 1:"))
    }

    @Test("sourceProfileIfPresent runs ~/.profile then ~/.bashrc and reports which it ran")
    func profileSourcing() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "export GREETING='hello from profile'\n"
            .write(to: dir.appendingPathComponent(".profile"),
                   atomically: true, encoding: .utf8)
        try "export FROM_BASHRC=1\n"
            .write(to: dir.appendingPathComponent(".bashrc"),
                   atomically: true, encoding: .utf8)

        let cap = CapturingShell()
        cap.shell.registerStandardCommands()

        let sourced = try await cap.shell.sourceProfileIfPresent(at: dir)
        #expect(sourced == [".profile", ".bashrc"])
        #expect(cap.shell.environment["GREETING"] == "hello from profile")
        #expect(cap.shell.environment["FROM_BASHRC"] == "1")
    }

    @Test("sourceProfileIfPresent skips missing files silently")
    func profileSourcingMissing() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cap = CapturingShell()
        cap.shell.registerStandardCommands()

        let sourced = try await cap.shell.sourceProfileIfPresent(at: dir)
        #expect(sourced.isEmpty)
    }
}
