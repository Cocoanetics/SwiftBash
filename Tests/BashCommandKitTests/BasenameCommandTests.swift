import Testing
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct BasenameCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(BasenameCommand.self)
        return cap
    }

    @Test func basicFileName() async throws {
        let cap = makeShell()
        try await cap.shell.run("basename /tmp/foo.txt")
        #expect(cap.stdout == "foo.txt\n")
    }

    @Test func noSlashesReturnsInput() async throws {
        let cap = makeShell()
        try await cap.shell.run("basename foo.txt")
        #expect(cap.stdout == "foo.txt\n")
    }

    @Test func trailingSlash() async throws {
        let cap = makeShell()
        try await cap.shell.run("basename /tmp/")
        #expect(cap.stdout == "tmp\n")
    }

    @Test func rootSlash() async throws {
        let cap = makeShell()
        try await cap.shell.run("basename /")
        #expect(cap.stdout == "/\n")
    }

    @Test func stripsSuffix() async throws {
        let cap = makeShell()
        try await cap.shell.run("basename /tmp/foo.txt .txt")
        #expect(cap.stdout == "foo\n")
    }

    @Test func suffixMismatchLeavesNameIntact() async throws {
        let cap = makeShell()
        try await cap.shell.run("basename /tmp/foo.txt .md")
        #expect(cap.stdout == "foo.txt\n")
    }

    @Test func suffixEqualToResultIsNotStripped() async throws {
        let cap = makeShell()
        try await cap.shell.run("basename .txt .txt")
        #expect(cap.stdout == ".txt\n")
    }

    @Test func deepPath() async throws {
        let cap = makeShell()
        try await cap.shell.run("basename /a/b/c/d/e")
        #expect(cap.stdout == "e\n")
    }

    @Test func missingPathFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("basename")
        #expect(!status.isSuccess)
        #expect(!cap.stderr.isEmpty)
    }
}
