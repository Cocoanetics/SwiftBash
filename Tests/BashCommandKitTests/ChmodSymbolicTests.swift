import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Symbolic-mode chmod parser tests. Numeric mode handling already lives
/// in the broader filesystem suite; this file pins the `u+x`/`go-w`/
/// `u=rwx,go=rx` parsing added with iBash adoption.
@Suite("chmod symbolic-mode parsing")
struct ChmodSymbolicTests {

    private func makeFile(in dir: URL,
                          name: String,
                          mode: UInt16) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path)
        return url
    }

    private func mode(of url: URL) throws -> UInt16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let n = attrs[.posixPermissions] as? NSNumber
        return UInt16(truncating: n ?? 0)
    }

    @Test("`chmod +x file` sets the execute bit for all without touching r/w")
    func plusX() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-chmod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = try makeFile(in: dir, name: "script.sh", mode: 0o644)

        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir.path

        let status = try await cap.shell.run("chmod +x script.sh")
        #expect(status == .success)
        #expect(try mode(of: file) == 0o755)
    }

    @Test("`chmod u+x` only adds execute for owner")
    func userPlusX() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-chmod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = try makeFile(in: dir, name: "script.sh", mode: 0o644)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir.path

        let status = try await cap.shell.run("chmod u+x script.sh")
        #expect(status == .success)
        #expect(try mode(of: file) == 0o744)
    }

    @Test("`chmod go-w` strips group/other write")
    func groupOtherMinusW() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-chmod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = try makeFile(in: dir, name: "f", mode: 0o666)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir.path

        let status = try await cap.shell.run("chmod go-w f")
        #expect(status == .success)
        #expect(try mode(of: file) == 0o644)
    }

    @Test("`chmod u=rwx,go=rx` uses `=` to replace bits exactly")
    func multipleClausesWithEquals() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-chmod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = try makeFile(in: dir, name: "f", mode: 0o000)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir.path

        let status = try await cap.shell.run("chmod u=rwx,go=rx f")
        #expect(status == .success)
        #expect(try mode(of: file) == 0o755)
    }

    @Test("`chmod 755` (numeric octal) still works")
    func numericStillWorks() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-chmod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = try makeFile(in: dir, name: "f", mode: 0o644)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir.path

        let status = try await cap.shell.run("chmod 755 f")
        #expect(status == .success)
        #expect(try mode(of: file) == 0o755)
    }

    @Test("invalid mode emits diagnostic and returns failure")
    func invalidMode() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-chmod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try makeFile(in: dir, name: "f", mode: 0o644)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir.path

        let status = try await cap.shell.run("chmod nonsense f")
        #expect(status != .success)
        #expect(cap.stderr.contains("invalid mode"))
    }
}
