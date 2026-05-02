import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Coverage for grep beyond the basic substring match in
/// `PipelineCommandsTests` — line numbers, count, files-with-matches,
/// quiet, regex, context, recursion, and `--include`.
@Suite(.timeLimit(.minutes(1))) struct GrepCommandTests {

    private func makeShell() -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString)
            .appendingPathComponent("grep-cmds-\(UUID())")
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

    // MARK: -n / -c / -l / -q

    @Test func dashNPrependsLineNumbers() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("seq 5 | grep -n 3")
        #expect(cap.stdout == "3:3\n")
    }

    @Test func dashCPrintsCount() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("seq 20 | grep -c 1")
        // 1, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 → 11 matches.
        #expect(cap.stdout == "11\n")
    }

    @Test func dashCAlsoPrintsZero() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("echo hello | grep -c nope")
        #expect(status == .failure)
        #expect(cap.stdout == "0\n")
    }

    #if !os(Windows)
    @Test func dashLPrintsFilenamesOnly() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hello world\n", to: "a.txt", in: dir)
        write("nothing here\n", to: "b.txt", in: dir)
        write("hello again\n", to: "c.txt", in: dir)
        try await cap.shell.run("grep -l hello a.txt b.txt c.txt")
        #expect(cap.stdout == "a.txt\nc.txt\n")
    }
    #endif

    @Test func dashQSuppressesOutput() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("echo hello | grep -q hello")
        #expect(status == .success)
        #expect(cap.stdout == "")
    }

    @Test func dashQFailsOnNoMatch() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("echo hello | grep -q nope")
        #expect(status == .failure)
        #expect(cap.stdout == "")
    }

    // MARK: File arguments

    #if !os(Windows)
    @Test func singleFileNoFilenamePrefix() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("alpha\nbeta\ngamma\n", to: "f.txt", in: dir)
        try await cap.shell.run("grep alpha f.txt")
        #expect(cap.stdout == "alpha\n")
    }
    #endif

    #if !os(Windows)
    @Test func multipleFilesShowFilenamePrefix() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("alpha\nbeta\n", to: "a.txt", in: dir)
        write("gamma\nalpha\n", to: "b.txt", in: dir)
        try await cap.shell.run("grep alpha a.txt b.txt")
        #expect(cap.stdout == "a.txt:alpha\nb.txt:alpha\n")
    }
    #endif

    @Test func directoryWithoutRecursiveFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub")
        let status = try await cap.shell.run("grep foo sub")
        #expect(status == .failure)
        #expect(cap.stderr.contains("Is a directory"))
    }

    @Test func missingFileReportsError() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("grep foo nope.txt")
        #expect(status == .failure)
        #expect(cap.stderr.contains("nope.txt"))
    }

    // MARK: -r / --include

    #if !os(Windows)
    @Test func recursiveDescendsIntoDirectories() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hello\n",   to: "src/a.swift", in: dir)
        write("hello\n",   to: "src/b.txt",   in: dir)
        write("nothing\n", to: "src/c.swift", in: dir)
        try await cap.shell.run("grep -r hello src")
        #expect(cap.stdout == "src/a.swift:hello\nsrc/b.txt:hello\n")
    }
    #endif

    #if !os(Windows)
    @Test func recursiveWithIncludeFiltersByGlob() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hello\n", to: "src/a.swift",  in: dir)
        write("hello\n", to: "src/b.txt",    in: dir)
        write("hello\n", to: "src/d/c.swift", in: dir)
        try await cap.shell.run("grep -rn --include=*.swift hello src")
        #expect(cap.stdout == """
            src/a.swift:1:hello
            src/d/c.swift:1:hello

            """)
    }
    #endif

    #if !os(Windows)
    @Test func recursiveWithMultipleIncludePatterns() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hit\n", to: "x.swift", in: dir)
        write("hit\n", to: "y.h",     in: dir)
        write("hit\n", to: "z.txt",   in: dir)
        try await cap.shell.run(
            "grep -r --include=*.swift --include=*.h hit .")
        #expect(cap.stdout == "./x.swift:hit\n./y.h:hit\n")
    }
    #endif

    // MARK: -E (extended regex)

    @Test func extendedRegexMatchesAlternation() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'foo\\nbar\\nbaz\\n' | grep -E 'foo|baz'")
        #expect(cap.stdout == "foo\nbaz\n")
    }

    @Test func extendedRegexAnchors() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'apple\\nbanana\\napricot\\n' | grep -E '^ap'")
        #expect(cap.stdout == "apple\napricot\n")
    }

    @Test func extendedRegexInvalidPatternFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run(
            "echo foo | grep -E '['")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("grep:"))
    }

    // MARK: -A / -B / -C

    @Test func dashAPrintsTrailingContext() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("seq 5 | grep -A 2 3")
        // match=3 ; +2 trailing → 4, 5
        #expect(cap.stdout == "3\n4\n5\n")
    }

    @Test func dashBPrintsLeadingContext() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("seq 5 | grep -B 2 4")
        // 2 leading + match → 2, 3, 4
        #expect(cap.stdout == "2\n3\n4\n")
    }

    @Test func dashCExpandsToBeforeAndAfter() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("seq 7 | grep -C 1 4")
        // 3, 4, 5
        #expect(cap.stdout == "3\n4\n5\n")
    }

    @Test func contextSeparatorBetweenNonContiguousGroups() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // Matches at lines 1 and 5 with -A 1 → groups "1,2" and "5,6"
        // separated by `--`.
        try await cap.shell.run(
            "printf 'hit\\nx\\nx\\nx\\nhit\\nx\\n' | grep -A 1 hit")
        #expect(cap.stdout == "hit\nx\n--\nhit\nx\n")
    }

    // MARK: Bundled flags

    #if !os(Windows)
    @Test func dashRNBundledWorks() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        write("hello\n", to: "a.txt", in: dir)
        try await cap.shell.run("grep -rn hello .")
        #expect(cap.stdout == "./a.txt:1:hello\n")
    }
    #endif
}
