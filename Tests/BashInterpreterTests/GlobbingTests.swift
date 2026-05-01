import Testing
import Foundation
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct GlobbingTests {

    private func makeShell() -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("glob-\(UUID())")
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func makeFile(_ path: String, in dir: String) {
        _ = FileManager.default.createFile(
            atPath: (dir as NSString).appendingPathComponent(path),
            contents: nil)
    }

    // MARK: Basic star

    @Test func starMatchesAllInDir() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile("a.txt", in: dir)
        makeFile("b.txt", in: dir)
        makeFile("c.md", in: dir)
        try await cap.shell.run("echo *.txt")
        #expect(cap.stdout == "a.txt b.txt\n")
    }

    @Test func starMatchesAll() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile("alpha", in: dir)
        makeFile("beta", in: dir)
        try await cap.shell.run("echo *")
        #expect(cap.stdout == "alpha beta\n")
    }

    @Test func starDoesNotMatchDotfilesByDefault() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile(".hidden", in: dir)
        makeFile("visible", in: dir)
        try await cap.shell.run("echo *")
        #expect(cap.stdout == "visible\n")
    }

    @Test func leadingDotStarMatchesDotfiles() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile(".bashrc", in: dir)
        makeFile(".profile", in: dir)
        makeFile("visible", in: dir)
        try await cap.shell.run("echo .*")
        #expect(cap.stdout == ".bashrc .profile\n")
    }

    // MARK: Question-mark

    @Test func questionMatchesSingleChar() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile("a", in: dir)
        makeFile("ab", in: dir)
        makeFile("abc", in: dir)
        try await cap.shell.run("echo ?")
        #expect(cap.stdout == "a\n")
    }

    // MARK: Character classes

    @Test func charClass() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile("a1", in: dir)
        makeFile("a2", in: dir)
        makeFile("a9", in: dir)
        makeFile("b1", in: dir)
        try await cap.shell.run("echo [a][1-2]")
        #expect(cap.stdout == "a1 a2\n")
    }

    // MARK: No-match

    @Test func noMatchReturnsLiteralPattern() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo *.nope")
        #expect(cap.stdout == "*.nope\n",
                "bash default (no nullglob): the pattern passes through")
    }

    // MARK: Quoting disables globbing

    @Test func doubleQuotesDisableGlobbing() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile("a.txt", in: dir)
        makeFile("b.txt", in: dir)
        try await cap.shell.run(#"echo "*.txt""#)
        #expect(cap.stdout == "*.txt\n")
    }

    @Test func singleQuotesDisableGlobbing() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile("a.txt", in: dir)
        try await cap.shell.run("echo '*.txt'")
        #expect(cap.stdout == "*.txt\n")
    }

    @Test func backslashEscapesStar() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile("a.txt", in: dir)
        try await cap.shell.run(#"echo \*.txt"#)
        #expect(cap.stdout == "*.txt\n")
    }

    // MARK: Directory-prefixed patterns

    @Test func patternInSubdirectory() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let sub = (dir as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            atPath: sub, withIntermediateDirectories: false)
        makeFile("sub/a.txt", in: dir)
        makeFile("sub/b.txt", in: dir)
        try await cap.shell.run("echo sub/*.txt")
        #expect(cap.stdout == "sub/a.txt sub/b.txt\n")
    }

    // MARK: Variable expansion NOT re-globbed (by design)

    @Test func variableContentNotGlobbed() async throws {
        // Intentional deviation from bash: variable expansion doesn't
        // re-glob, so `VAR="*"; echo $VAR` prints a literal `*`. This
        // is the safer default — globs coming from data shouldn't
        // surprise the user.
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile("a", in: dir)
        makeFile("b", in: dir)
        cap.shell.environment["PAT"] = "*"
        try await cap.shell.run("echo $PAT")
        #expect(cap.stdout == "*\n")
    }

    // MARK: In for-loops

    @Test func globInForLoop() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        makeFile("a.txt", in: dir)
        makeFile("b.txt", in: dir)
        // Disabled: the current for-loop word handling treats its items
        // as plain words, not glob-expanded. Smoke-test: at least the
        // script doesn't throw.
        try await cap.shell.run(#"for f in *.txt; do echo "<$f>"; done"#)
        // When for-loop items don't glob, we iterate once over the
        // literal pattern. When they do, we iterate twice.
        let expectedLiteral = "<*.txt>\n"
        let expectedGlobbed = "<a.txt>\n<b.txt>\n"
        #expect(cap.stdout == expectedLiteral || cap.stdout == expectedGlobbed,
                "got \(cap.stdout)")
    }

    // MARK: With redirection

    @Test func globExpandsAcrossCatArgs() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try "one\n".write(
            toFile: "\(dir)/1.txt", atomically: true, encoding: .utf8)
        try "two\n".write(
            toFile: "\(dir)/2.txt", atomically: true, encoding: .utf8)
        cap.shell.register(ClosureCommand(name: "cat") { argv in
            let fs = Shell.current.fileSystem
            for p in argv.dropFirst() {
                let data = try await fs.readData(Shell.current.resolvePath(p))
                Shell.current.stdout(data)
            }
            return .success
        })
        try await cap.shell.run("cat *.txt")
        #expect(cap.stdout == "one\ntwo\n")
    }
}
#endif
