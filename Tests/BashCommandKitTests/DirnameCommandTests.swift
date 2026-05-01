import Testing
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct DirnameCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(DirnameCommand.self)
        return cap
    }

    @Test func simplePath() async throws {
        let cap = makeShell()
        try await cap.shell.run("dirname /tmp/foo.txt")
        #expect(cap.stdout == "/tmp\n")
    }

    @Test func noSlashReturnsDot() async throws {
        let cap = makeShell()
        try await cap.shell.run("dirname foo.txt")
        #expect(cap.stdout == ".\n")
    }

    @Test func relativePath() async throws {
        let cap = makeShell()
        try await cap.shell.run("dirname foo/bar")
        #expect(cap.stdout == "foo\n")
    }

    @Test func trailingSlashReturnsParent() async throws {
        let cap = makeShell()
        try await cap.shell.run("dirname /tmp/")
        #expect(cap.stdout == "/\n")
    }

    @Test func rootPath() async throws {
        let cap = makeShell()
        try await cap.shell.run("dirname /foo")
        #expect(cap.stdout == "/\n")
    }

    @Test func rootSlashItself() async throws {
        let cap = makeShell()
        try await cap.shell.run("dirname /")
        #expect(cap.stdout == "/\n")
    }

    @Test func deepPath() async throws {
        let cap = makeShell()
        try await cap.shell.run("dirname /a/b/c/d/e")
        #expect(cap.stdout == "/a/b/c/d\n")
    }

    @Test func emptyStringReturnsDot() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"dirname """#)
        #expect(cap.stdout == ".\n")
    }
}
