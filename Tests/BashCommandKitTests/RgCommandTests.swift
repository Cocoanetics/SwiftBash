import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct RgCommandTests {

    private func makeShell() -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString)
            .appendingPathComponent("rg-cmds-\(UUID())")
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func write(_ contents: String, to path: String, in dir: String) {
        let p = (dir as NSString).appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? contents.write(toFile: p, atomically: true, encoding: .utf8)
    }

    // MARK: Defaults

    @Test func recursiveByDefault() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hello\n", to: "a.txt",      in: dir)
        write("hello\n", to: "sub/b.txt",  in: dir)
        write("nope\n",  to: "sub/c.txt",  in: dir)
        try await cap.shell.run("rg hello")
        #expect(cap.stdout == "./a.txt:hello\n./sub/b.txt:hello\n")
    }

    @Test func skipsHiddenByDefault() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\n", to: "visible.txt", in: dir)
        write("hit\n", to: ".hidden.txt", in: dir)
        write("hit\n", to: ".d/inner.txt", in: dir)
        try await cap.shell.run("rg hit")
        #expect(cap.stdout == "./visible.txt:hit\n")
    }

    @Test func hiddenFlagIncludesDotEntries() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\n", to: "visible.txt", in: dir)
        write("hit\n", to: ".hidden.txt", in: dir)
        try await cap.shell.run("rg --hidden hit")
        #expect(cap.stdout == "./.hidden.txt:hit\n./visible.txt:hit\n")
    }

    @Test func patternIsRegex() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("foo\nbar\nbaz\n", to: "a.txt", in: dir)
        try await cap.shell.run("rg 'foo|baz'")
        #expect(cap.stdout == "./a.txt:foo\n./a.txt:baz\n")
    }

    // MARK: Output flags

    @Test func dashNAddsLineNumbers() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("a\nfoo\nb\nfoo\n", to: "x.txt", in: dir)
        try await cap.shell.run("rg -n foo")
        #expect(cap.stdout == "./x.txt:2:foo\n./x.txt:4:foo\n")
    }

    @Test func dashLPrintsFilenamesOnly() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\n", to: "a.txt", in: dir)
        write("hit\n", to: "b.txt", in: dir)
        write("nope\n", to: "c.txt", in: dir)
        try await cap.shell.run("rg -l hit")
        #expect(cap.stdout == "./a.txt\n./b.txt\n")
    }

    @Test func dashQSuppressesOutput() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\n", to: "a.txt", in: dir)
        let status = try await cap.shell.run("rg -q hit")
        #expect(status == .success)
        #expect(cap.stdout == "")
    }

    @Test func dashMLimitsMatchesPerFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\nhit\nhit\nhit\n", to: "a.txt", in: dir)
        try await cap.shell.run("rg -m 2 hit")
        #expect(cap.stdout == "./a.txt:hit\n./a.txt:hit\n")
    }

    // MARK: Case sensitivity

    @Test func defaultIsCaseSensitive() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("Foo\nfoo\n", to: "a.txt", in: dir)
        try await cap.shell.run("rg foo")
        #expect(cap.stdout == "./a.txt:foo\n")
    }

    @Test func dashIIsCaseInsensitive() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("Foo\nfoo\n", to: "a.txt", in: dir)
        try await cap.shell.run("rg -i foo")
        #expect(cap.stdout == "./a.txt:Foo\n./a.txt:foo\n")
    }

    @Test func smartCaseLowerPatternMatchesAnyCase() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("Foo\nfoo\n", to: "a.txt", in: dir)
        try await cap.shell.run("rg -S foo")
        #expect(cap.stdout == "./a.txt:Foo\n./a.txt:foo\n")
    }

    @Test func smartCaseUpperPatternStaysCaseSensitive() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("Foo\nfoo\n", to: "a.txt", in: dir)
        try await cap.shell.run("rg -S Foo")
        #expect(cap.stdout == "./a.txt:Foo\n")
    }

    // MARK: -g / --glob

    @Test func dashGFiltersToInclude() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\n", to: "a.swift", in: dir)
        write("hit\n", to: "b.txt",   in: dir)
        write("hit\n", to: "c.swift", in: dir)
        try await cap.shell.run("rg -g '*.swift' hit")
        #expect(cap.stdout == "./a.swift:hit\n./c.swift:hit\n")
    }

    @Test func dashGNegationExcludes() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\n", to: "a.swift", in: dir)
        write("hit\n", to: "b.txt",   in: dir)
        try await cap.shell.run("rg -g '!*.txt' hit")
        #expect(cap.stdout == "./a.swift:hit\n")
    }

    @Test func multipleGlobsAreUnioned() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\n", to: "a.swift", in: dir)
        write("hit\n", to: "b.h",     in: dir)
        write("hit\n", to: "c.txt",   in: dir)
        try await cap.shell.run("rg -g '*.swift' -g '*.h' hit")
        #expect(cap.stdout == "./a.swift:hit\n./b.h:hit\n")
    }

    // MARK: --files

    @Test func filesListsCandidatesWithoutSearching() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("anything\n", to: "a.swift",      in: dir)
        write("anything\n", to: "sub/b.swift",  in: dir)
        write("anything\n", to: "c.txt",        in: dir)
        try await cap.shell.run("rg --files -g '*.swift'")
        #expect(cap.stdout == "./a.swift\n./sub/b.swift\n")
    }

    @Test func filesAlsoSkipsHidden() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("anything\n", to: "v.txt",  in: dir)
        write("anything\n", to: ".h.txt", in: dir)
        try await cap.shell.run("rg --files")
        #expect(cap.stdout == "./v.txt\n")
    }

    // MARK: Context

    @Test func contextSeparatorBetweenGroups() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\nx\nx\nx\nhit\nx\n", to: "a.txt", in: dir)
        try await cap.shell.run("rg -A 1 hit")
        #expect(cap.stdout == """
            ./a.txt:hit
            ./a.txt-x
            --
            ./a.txt:hit
            ./a.txt-x

            """)
    }

    // MARK: Error cases

    @Test func missingPatternFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("rg")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("PATTERN"))
    }

    @Test func missingPathFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("rg foo nope")
        #expect(status == .failure)
        #expect(cap.stderr.contains("nope"))
    }

    @Test func invalidRegexFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("anything\n", to: "a.txt", in: dir)
        let status = try await cap.shell.run("rg '['")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("rg:"))
    }
}
