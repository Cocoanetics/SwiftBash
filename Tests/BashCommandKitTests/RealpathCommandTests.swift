import XCTest
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

final class RealpathCommandTests: XCTestCase {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(RealpathCommand.self)
        return cap
    }

    func testResolvesExistingAbsolutePath() async throws {
        let cap = makeShell()
        try await cap.shell.run("realpath /tmp")
        let out = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // On macOS /tmp is a symlink to /private/tmp — we resolve symlinks.
        XCTAssertTrue(out == "/tmp" || out == "/private/tmp",
                      "got `\(out)`")
    }

    func testNormalisesDotDot() async throws {
        // Use a non-symlinked path so we don't need to care about
        // macOS's /tmp → /private/tmp symlink.
        let cap = makeShell()
        try await cap.shell.run("realpath /usr/bin/..")
        XCTAssertEqual(
            cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "/usr"
        )
    }

    func testMissingPathFailsByDefault() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("realpath /definitely/not/a/real/path")
        XCTAssertFalse(status.isSuccess)
        XCTAssertTrue(cap.stderr.contains("No such file"), cap.stderr)
    }

    func testMissingFlagAllowsNonexistentPath() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("realpath -m /definitely/not/a/real/path")
        XCTAssertEqual(status, .success)
        XCTAssertEqual(cap.stdout,
                       "/definitely/not/a/real/path\n")
    }

    func testRelativePathUsesShellCwd() async throws {
        let cap = makeShell()
        cap.shell.environment.workingDirectory = "/tmp"
        try await cap.shell.run("realpath -m sub/file.txt")
        let out = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(out.hasSuffix("/tmp/sub/file.txt")
                   || out.hasSuffix("/private/tmp/sub/file.txt"),
                      "got `\(out)`")
    }

    func testTildeUsesHome() async throws {
        let cap = makeShell()
        cap.shell.environment["HOME"] = "/Users/foo"
        try await cap.shell.run("realpath -m ~/docs")
        XCTAssertEqual(
            cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "/Users/foo/docs"
        )
    }
}
