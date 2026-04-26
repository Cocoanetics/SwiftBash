import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct SedCommandTests {

    private func makeShell() -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString)
            .appendingPathComponent("sed-cmds-\(UUID())")
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

    // MARK: substitution

    @Test func substituteFirstMatchPerLine() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'foo foo\\nbar foo\\n' | sed 's/foo/baz/'")
        // Without `g`, only the first per line is replaced.
        #expect(cap.stdout == "baz foo\nbar baz\n")
    }

    @Test func substituteGlobalReplacesAll() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'foo foo foo\\n' | sed 's/foo/x/g'")
        #expect(cap.stdout == "x x x\n")
    }

    @Test func backreferences() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // Default mode is BRE — groups need backslashes.
        try await cap.shell.run(
            #"echo 'hello world' | sed 's/\(hello\) \(world\)/\2 \1/'"#)
        #expect(cap.stdout == "world hello\n")
    }

    @Test func backreferencesERE() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            #"echo 'hello world' | sed -E 's/(hello) (world)/\2 \1/'"#)
        #expect(cap.stdout == "world hello\n")
    }

    @Test func ampersandIsWholeMatch() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "echo abc | sed 's/b/[&]/'")
        #expect(cap.stdout == "a[b]c\n")
    }

    // MARK: -n + p flag

    @Test func quietPlusPrintFlagExtractsMatches() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        // The classic "extract" idiom: print only lines where s/// hit.
        try await cap.shell.run(
            "printf 'name: alice\\nage: 30\\nname: bob\\n'"
                + " | sed -n 's/name: //p'")
        #expect(cap.stdout == "alice\nbob\n")
    }

    @Test func quietWithoutPMakesNoOutput() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "echo hello | sed -n 's/hello/world/'")
        #expect(cap.stdout == "")
    }

    // MARK: addresses

    @Test func lineNumberAddressDelete() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("seq 5 | sed '3d'")
        #expect(cap.stdout == "1\n2\n4\n5\n")
    }

    @Test func dollarAddressDeletesLastLine() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("seq 4 | sed '$d'")
        #expect(cap.stdout == "1\n2\n3\n")
    }

    @Test func regexAddressPrintsMatching() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'apple\\nbanana\\napricot\\n' | sed -n '/^ap/p'")
        #expect(cap.stdout == "apple\napricot\n")
    }

    @Test func lineNumberAddressSubstitute() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "seq 3 | sed '2 s/.*/two/'")
        #expect(cap.stdout == "1\ntwo\n3\n")
    }

    // MARK: multiple expressions

    @Test func dashEAccumulatesPrograms() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "echo hello | sed -e 's/h/H/' -e 's/o/0/'")
        #expect(cap.stdout == "Hell0\n")
    }

    @Test func semicolonSeparatesCommands() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("echo abc | sed 's/a/A/;s/c/C/'")
        #expect(cap.stdout == "AbC\n")
    }

    // MARK: file input + -i

    @Test func sedReadsFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let p = (dir as NSString).appendingPathComponent("data.txt")
        try "alpha\nbeta\n".write(toFile: p, atomically: true, encoding: .utf8)
        try await cap.shell.run("sed 's/a/A/g' data.txt")
        #expect(cap.stdout == "AlphA\nbetA\n")
    }

    @Test func inPlaceRewritesFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let p = (dir as NSString).appendingPathComponent("data.txt")
        try "foo\nbar\n".write(toFile: p, atomically: true, encoding: .utf8)
        try await cap.shell.run("sed -i 's/foo/baz/' data.txt")
        let after = try String(contentsOfFile: p, encoding: .utf8)
        #expect(after == "baz\nbar\n")
        // -i shouldn't print to stdout.
        #expect(cap.stdout == "")
    }

    @Test func inPlaceRequiresFile() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("echo x | sed -i 's/x/y/'")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("-i"))
    }

    // MARK: error reporting

    @Test func unterminatedSubstituteFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("echo x | sed 's/foo/bar'")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("sed:"))
    }

    @Test func unknownActionFails() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("echo x | sed 'X'")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("sed:"))
    }
}
