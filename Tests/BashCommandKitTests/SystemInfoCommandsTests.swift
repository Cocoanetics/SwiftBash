import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct SystemInfoCommandsTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func unameDefault() async throws {
        let cap = makeShell()
        try await cap.shell.run("uname")
        // On macOS prints "Darwin\n"
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines).count > 0)
    }

    @Test func unameMachine() async throws {
        let cap = makeShell()
        try await cap.shell.run("uname -m")
        let m = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(m == "arm64" || m == "x86_64" || m == "i386")
    }

    @Test func unameAll() async throws {
        let cap = makeShell()
        try await cap.shell.run("uname -a")
        let parts = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        #expect(parts.count >= 3)
    }

    @Test func idDefault() async throws {
        let cap = makeShell()
        try await cap.shell.run("id")
        #expect(cap.stdout.contains("uid="))
        #expect(cap.stdout.contains("gid="))
    }

    @Test func idUserOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run("id -u")
        let s = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(s) != nil)
    }

    @Test func idUserName() async throws {
        let cap = makeShell()
        try await cap.shell.run("id -un")
        let s = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Synthetic by default — never the real host's user name.
        #expect(s == "user")
    }

    @Test func dfDefault() async throws {
        let cap = makeShell()
        try await cap.shell.run("df /")
        #expect(cap.stdout.contains("Filesystem"))
        #expect(cap.stdout.contains("/"))
    }

    @Test func dfHumanReadable() async throws {
        let cap = makeShell()
        try await cap.shell.run("df -h /")
        // Should contain a size suffix.
        let body = cap.stdout
        #expect(body.contains("G") || body.contains("M") || body.contains("K") || body.contains("T"))
    }

    #if !os(Windows)
    @Test func cmpEqual() async throws {
        let cap = makeShell()
        let dir = NSTemporaryDirectory() + "cmp-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "abc\n".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "abc\n".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        let status = try await cap.shell.run("cmp \(dir)/a \(dir)/b")
        #expect(status == .success)
        #expect(cap.stdout == "")
    }
    #endif

    #if !os(Windows)
    @Test func cmpDifferent() async throws {
        let cap = makeShell()
        let dir = NSTemporaryDirectory() + "cmp-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "abc\n".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "abd\n".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        let status = try await cap.shell.run("cmp \(dir)/a \(dir)/b")
        #expect(status == ExitStatus(1))
        #expect(cap.stdout.contains("differ"))
    }
    #endif

    #if !os(Windows)
    @Test func cmpSilent() async throws {
        let cap = makeShell()
        let dir = NSTemporaryDirectory() + "cmp-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "abc".write(toFile: dir + "/a", atomically: true, encoding: .utf8)
        try "abd".write(toFile: dir + "/b", atomically: true, encoding: .utf8)
        let status = try await cap.shell.run("cmp -s \(dir)/a \(dir)/b")
        #expect(status == ExitStatus(1))
        #expect(cap.stdout == "")
    }
    #endif

}
#endif
