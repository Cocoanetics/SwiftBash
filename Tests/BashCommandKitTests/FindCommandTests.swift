import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// End-to-end tests for `find`. Each test uses a fresh temp directory
/// and `cd`s into it so relative paths in the script just work.
///
/// Output ordering is deterministic — `FindCommand` sorts directory
/// entries before recursing — so we can assert on exact strings.
#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct FindCommandTests {

    private func makeShell() -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString)
            .appendingPathComponent("find-cmds-\(UUID())")
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

    // MARK: Basics

    @Test func findIsRegistered() {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        #expect(cap.shell.commands["find"] != nil)
    }

    @Test func walksTreeIncludingStartPath() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p sub/inner")
        try await cap.shell.run("touch a sub/b sub/inner/c")
        try await cap.shell.run("find .")
        #expect(cap.stdout == """
            .
            ./a
            ./sub
            ./sub/b
            ./sub/inner
            ./sub/inner/c

            """)
    }

    @Test func defaultPathIsDot() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a")
        try await cap.shell.run("find")
        #expect(cap.stdout == ".\n./a\n")
    }

    @Test func multipleStartPaths() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir x y")
        try await cap.shell.run("touch x/a y/b")
        try await cap.shell.run("find x y")
        #expect(cap.stdout == "x\nx/a\ny\ny/b\n")
    }

    @Test func missingStartPathFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("find nope")
        #expect(status == .failure)
        #expect(cap.stderr.contains("nope"))
    }

    // MARK: -name / -iname / -path

    @Test func nameMatchesBasenameGlob() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub")
        try await cap.shell.run("touch a.txt b.md sub/c.txt sub/d.log")
        try await cap.shell.run("find . -name '*.txt'")
        #expect(cap.stdout == "./a.txt\n./sub/c.txt\n")
    }

    @Test func nameDoesNotMatchFullPath() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub")
        try await cap.shell.run("touch sub/a.txt")
        // `-name 'sub/*'` matches against the basename only, so no hits.
        try await cap.shell.run("find . -name 'sub/*'")
        #expect(cap.stdout == "")
    }

    @Test func iNameIsCaseInsensitive() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch README.md notes.MD")
        try await cap.shell.run("find . -iname '*.md'")
        #expect(cap.stdout == "./README.md\n./notes.MD\n")
    }

    @Test func pathMatchesFullPathGlob() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p sub/inner")
        try await cap.shell.run("touch sub/a sub/inner/b")
        try await cap.shell.run("find . -path '*/inner/*'")
        #expect(cap.stdout == "./sub/inner/b\n")
    }

    // MARK: -type

    @Test func typeFiltersFiles() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub")
        try await cap.shell.run("touch a sub/b")
        try await cap.shell.run("find . -type f")
        #expect(cap.stdout == "./a\n./sub/b\n")
    }

    @Test func typeFiltersDirectories() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p sub/inner")
        try await cap.shell.run("touch a sub/b")
        try await cap.shell.run("find . -type d")
        #expect(cap.stdout == ".\n./sub\n./sub/inner\n")
    }

    @Test func unknownTypeFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("find . -type z")
        #expect(status == .failure)
        #expect(cap.stderr.contains("-type"))
    }

    // MARK: -maxdepth / -mindepth

    @Test func maxDepthZeroOnlyChecksStart() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p sub/inner")
        try await cap.shell.run("touch sub/a")
        try await cap.shell.run("find . -maxdepth 0")
        #expect(cap.stdout == ".\n")
    }

    @Test func maxDepthOneIsImmediateChildren() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p sub/inner")
        try await cap.shell.run("touch top sub/a sub/inner/b")
        try await cap.shell.run("find . -maxdepth 1")
        #expect(cap.stdout == ".\n./sub\n./top\n")
    }

    @Test func minDepthOneSkipsStart() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a b")
        try await cap.shell.run("find . -mindepth 1")
        #expect(cap.stdout == "./a\n./b\n")
    }

    @Test func combiningMaxAndMinDepth() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p sub/inner")
        try await cap.shell.run("touch top sub/a sub/inner/b")
        try await cap.shell.run("find . -mindepth 1 -maxdepth 2")
        #expect(cap.stdout == "./sub\n./sub/a\n./sub/inner\n./top\n")
    }

    // MARK: Combined predicates

    @Test func nameAndTypeAreAnded() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir docs")
        try await cap.shell.run("touch docs.txt docs/readme.txt")
        try await cap.shell.run("find . -type f -name '*.txt'")
        // Sorted basename order: "docs" < "docs.txt", so we descend into
        // docs/ before visiting the sibling docs.txt.
        #expect(cap.stdout == "./docs/readme.txt\n./docs.txt\n")
    }

    @Test func emptyMatchesEmptyFilesAndDirs() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir empty-dir nonempty-dir")
        try await cap.shell.run("touch empty-file")
        let withBytes = (dir as NSString)
            .appendingPathComponent("nonempty-dir/x")
        try "hi".write(toFile: withBytes, atomically: true, encoding: .utf8)
        let solo = (dir as NSString).appendingPathComponent("nonempty-file")
        try "hello".write(toFile: solo, atomically: true, encoding: .utf8)
        try await cap.shell.run("find . -empty")
        #expect(cap.stdout == "./empty-dir\n./empty-file\n")
    }

    @Test func printIsAcceptedAsNoOp() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a")
        try await cap.shell.run("find . -print")
        #expect(cap.stdout == ".\n./a\n")
    }

    @Test func unknownPredicateFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("find . -bogus")
        #expect(status == .failure)
        #expect(cap.stderr.contains("-bogus"))
    }

    @Test func missingValueForNameFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("find . -name")
        #expect(status == .failure)
        #expect(cap.stderr.contains("-name"))
    }

    // MARK: Pipeline

    @Test func findIntoGrep() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub")
        try await cap.shell.run("touch a.txt b.md sub/c.txt")
        try await cap.shell.run("find . -type f | grep .txt")
        #expect(cap.stdout == "./a.txt\n./sub/c.txt\n")
    }

    // MARK: Boolean operators

    @Test func notInvertsName() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a.txt b.md c.txt")
        try await cap.shell.run("find . -type f -not -name '*.txt'")
        #expect(cap.stdout == "./b.md\n")
    }

    @Test func bangIsAliasForNot() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a.txt b.md")
        // Bash needs `\!` so the history-expansion off shell doesn't
        // touch it; `!` on its own arrives as a literal token here.
        try await cap.shell.run("find . -type f '!' -name '*.md'")
        #expect(cap.stdout == "./a.txt\n")
    }

    @Test func orMatchesEither() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a.md b.txt c.log")
        try await cap.shell.run(
            "find . -type f \\( -name '*.md' -o -name '*.txt' \\)")
        #expect(cap.stdout == "./a.md\n./b.txt\n")
    }

    @Test func explicitAndIsSameAsImplicit() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir d")
        try await cap.shell.run("touch a.txt d/b.txt")
        try await cap.shell.run("find . -type f -a -name 'a.*'")
        #expect(cap.stdout == "./a.txt\n")
    }

    @Test func parenthesesGroup() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a.md b.txt c.log")
        // `( -name a.md -o -name c.log ) -a -type f`
        try await cap.shell.run(
            "find . \\( -name a.md -o -name c.log \\) -type f")
        #expect(cap.stdout == "./a.md\n./c.log\n")
    }

    // MARK: -print0

    @Test func print0UsesNullSeparator() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a b")
        try await cap.shell.run("find . -type f -print0")
        #expect(cap.stdout == "./a\u{0}./b\u{0}")
    }

    // MARK: -prune

    @Test func pruneSkipsDirectoryDescent() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p keep skip")
        try await cap.shell.run("touch keep/a skip/b")
        // Standard idiom: prune the matched dir, OR print everything else.
        // Note: `./skip` itself isn't printed — the LHS short-circuits OR
        // before -print runs, matching GNU/BSD find behavior. We just
        // never descend into it, so `skip/b` is excluded.
        try await cap.shell.run(
            "find . -name skip -prune -o -print")
        #expect(cap.stdout == ".\n./keep\n./keep/a\n")
    }

    // MARK: -delete

    @Test func deleteRemovesMatchingFiles() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch keep.md gone.txt also-gone.txt")
        try await cap.shell.run("find . -type f -name '*.txt' -delete")
        try await cap.shell.run("ls")
        #expect(cap.stdout == "keep.md\n")
    }

    @Test func deleteRemovesEmptyDirsViaImpliedDepth() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p outer/inner")
        try await cap.shell.run("touch outer/inner/file")
        // -delete implies -depth, so children are removed first and the
        // dir is empty by the time we try to delete it.
        try await cap.shell.run("find outer -delete")
        let status = try await cap.shell.run("ls outer")
        #expect(status == .failure)  // outer was deleted
    }

    // MARK: -newer

    @Test func newerFiltersByMtime() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let oldPath = (dir as NSString).appendingPathComponent("old")
        let refPath = (dir as NSString).appendingPathComponent("ref")
        let newPath = (dir as NSString).appendingPathComponent("new")
        try Data().write(to: URL(fileURLWithPath: oldPath))
        try Data().write(to: URL(fileURLWithPath: refPath))
        try Data().write(to: URL(fileURLWithPath: newPath))
        let fm = FileManager.default
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: oldPath)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)],
            ofItemAtPath: refPath)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3_000_000)],
            ofItemAtPath: newPath)
        try await cap.shell.run("find . -type f -newer ref")
        #expect(cap.stdout == "./new\n")
    }

    @Test func newerOnMissingReferenceFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("find . -newer nope")
        #expect(status == .failure)
        #expect(cap.stderr.contains("nope"))
    }

    // MARK: -depth

    @Test func depthVisitsContentsBeforeContainer() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p sub/inner")
        try await cap.shell.run("touch sub/a sub/inner/b")
        try await cap.shell.run("find . -depth")
        #expect(cap.stdout == """
            ./sub/a
            ./sub/inner/b
            ./sub/inner
            ./sub
            .

            """)
    }

    // MARK: -exec ... ;

    @Test func execEachRunsCommandPerMatch() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a b c")
        // `echo' runs once per match; `{}` becomes the path.
        try await cap.shell.run(
            "find . -type f -exec echo found: {} \\;")
        #expect(cap.stdout == "found: ./a\nfound: ./b\nfound: ./c\n")
    }

    @Test func execEachExitStatusFiltersFollowingPredicates() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a.txt b.md")
        // `true` always succeeds → -print runs. `false` would suppress.
        try await cap.shell.run(
            "find . -type f -exec true \\; -print")
        #expect(cap.stdout == "./a.txt\n./b.md\n")
    }

    @Test func execEachWithFalseSuppressesPrint() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a.txt")
        try await cap.shell.run(
            "find . -type f -exec false \\; -print")
        #expect(cap.stdout == "")
    }

    // MARK: -exec ... +

    @Test func execBatchRunsOnceWithAllPaths() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch a b c")
        // `echo a b c` would print "a b c"; we want all paths joined.
        try await cap.shell.run(
            "find . -type f -exec echo {} +")
        #expect(cap.stdout == "./a ./b ./c\n")
    }

    @Test func execMissingTerminatorFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run(
            "find . -exec echo {}")
        #expect(status == .failure)
        #expect(cap.stderr.contains("-exec"))
    }
}
#endif
