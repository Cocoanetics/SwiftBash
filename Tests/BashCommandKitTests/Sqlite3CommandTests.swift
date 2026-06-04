import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// `sqlite3` is registered (via `registerSqlite3()`) from SwiftPorts'
/// ArgumentParser-free `Sqlite3Shell` driver through a native ShellKit
/// command, so — unlike the rest of the SwiftPorts CLI family — it builds
/// and runs on every platform. These tests are intentionally **not** gated
/// off Android: they run on the emulator in CI and are what proves the
/// `sqlite3` builtin works there.
@Suite(.timeLimit(.minutes(1))) struct Sqlite3CommandTests {

    private func makeShell() throws -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("sqlite3-\(UUID())")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func inlineSelectAgainstMemory() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("sqlite3 :memory: \"SELECT 1 + 1;\"")
        #expect(status == .success)
        #expect(cap.stdout == "2\n")
    }

    @Test func multiStatementInlineCrud() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run(
            "sqlite3 :memory: \"CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);"
            + " INSERT INTO t(name) VALUES('a'),('b'); SELECT id || ':' || name FROM t;\"")
        #expect(status == .success)
        #expect(cap.stdout == "1:a\n2:b\n")
    }

    @Test func scriptViaStdin() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        // Feed SQL on stdin (no trailing SQL arg) — the read-all-stdin path.
        try await cap.shell.run(
            "printf 'CREATE TABLE t(x);\\nINSERT INTO t VALUES(7),(8);\\nSELECT sum(x) FROM t;\\n'"
            + " | sqlite3 :memory:")
        #expect(cap.stdout == "15\n")
    }

    @Test func csvModeWithHeader() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "sqlite3 -csv -header :memory: \"SELECT 1 AS a, 'x' AS b;\"")
        #expect(cap.stdout == "a,b\n1,x\n")
    }

    @Test func dotTablesIntrospection() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'CREATE TABLE foo(a);\\nCREATE TABLE bar(b);\\n.tables\\n' | sqlite3 :memory:")
        #expect(cap.stdout.contains("foo"))
        #expect(cap.stdout.contains("bar"))
    }

    /// A file-backed database round-trips across two invocations — this
    /// drives `Shell.resolve` + `Shell.authorize` (the sandbox gate), the
    /// path that distinguishes the in-process port from a forked binary.
    @Test func fileBackedRoundTrip() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        let create = try await cap.shell.run(
            "sqlite3 data.db \"CREATE TABLE t(x); INSERT INTO t VALUES(42);\"")
        #expect(create == .success)
        let read = try await cap.shell.run("sqlite3 data.db \"SELECT x FROM t;\"")
        #expect(read == .success)
        #expect(cap.stdout == "42\n")
        // The database file actually landed on disk in the working dir.
        #expect(FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("data.db")))
    }

    @Test func doubleDashVersionGivesUniformBanner() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        // `--version` (double dash) gets SwiftBash's uniform builtin banner,
        // matching the ArgumentParser bridge the other commands route through.
        try await cap.shell.run("sqlite3 --version")
        #expect(cap.stdout == "sqlite3 (SwiftBash) \(SwiftBashVersion.packageVersion)\n")
    }

    @Test func singleDashVersionGivesSQLiteVersion() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        // `-version` (single dash, real sqlite3's spelling) is handled by the
        // driver and reports the SQLite library version, not the banner.
        try await cap.shell.run("sqlite3 -version")
        #expect(cap.stdout.hasSuffix(" (64-bit)\n"))
        #expect(!cap.stdout.contains("SwiftBash"))
    }
}
