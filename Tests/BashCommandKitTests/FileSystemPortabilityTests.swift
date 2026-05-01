import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Runs the same bash script against `RealFileSystem` and
/// `InMemoryFileSystem` and asserts they produce identical
/// `stdout` + `stderr`. This is how we lock down the FileSystem
/// abstraction: every shell-visible behaviour has to be a pure
/// function of the FS, not the environment.
@Suite(.timeLimit(.minutes(1))) struct FileSystemPortabilityTests {

    /// Build a shell rooted in a fresh empty cwd on the chosen FS.
    private func makeRealShell() async throws -> (CapturingShell, () -> Void) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("port-real-\(UUID())")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.fileSystem = RealFileSystem()
        cap.shell.environment.workingDirectory = dir
        cap.shell.environment["HOME"] = dir
        cap.shell.registerStandardCommands()
        return (cap, {
            try? FileManager.default.removeItem(atPath: dir)
        })
    }

    private func makeMemoryShell() async throws -> CapturingShell {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory("/work", intermediates: true)
        let cap = CapturingShell()
        cap.shell.fileSystem = fs
        cap.shell.environment.workingDirectory = "/work"
        cap.shell.environment["HOME"] = "/work"
        cap.shell.registerStandardCommands()
        return cap
    }

    /// Run `script` against both FS backends and assert identical
    /// `cap.stdout` and `cap.stderr`. Returns the real-FS capture so
    /// callers can make additional assertions.
    @discardableResult
    private func onBoth(
        _ script: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> CapturingShell
    {
        let (real, teardown) = try await makeRealShell()
        defer { teardown() }
        let mem = try await makeMemoryShell()

        try await real.shell.run(script)
        try await mem.shell.run(script)

        #expect(real.stdout == mem.stdout,
                "stdout differs between real and in-memory FS",
                sourceLocation: sourceLocation)
        #expect(real.stderr == mem.stderr,
                "stderr differs between real and in-memory FS",
                sourceLocation: sourceLocation)
        return real
    }

    // MARK: Fundamentals

    @Test func touchAndList() async throws {
        let r = try await onBoth("touch a b c; ls")
        #expect(r.stdout == "a\nb\nc\n")
    }

    @Test func mkdirAndListSubdir() async throws {
        let r = try await onBoth("""
            mkdir sub
            touch sub/x sub/y
            ls sub
            """)
        #expect(r.stdout == "x\ny\n")
    }

    @Test func mkdirPNestedThenFind() async throws {
        let r = try await onBoth("""
            mkdir -p a/b/c
            touch a/b/c/leaf
            ls a/b/c
            """)
        #expect(r.stdout == "leaf\n")
    }

    // MARK: File CRUD

    @Test func writeReadCycle() async throws {
        let r = try await onBoth("""
            echo hello > greeting.txt
            cat greeting.txt
            """)
        #expect(r.stdout == "hello\n")
    }

    @Test func appendLog() async throws {
        let r = try await onBoth("""
            echo first > log
            echo second >> log
            echo third >> log
            cat log
            """)
        #expect(r.stdout == "first\nsecond\nthird\n")
    }

    @Test func rmRfSubtree() async throws {
        let r = try await onBoth("""
            mkdir -p tree/inner
            touch tree/a tree/inner/b
            rm -rf tree
            ls
            """)
        #expect(r.stdout == "")
    }

    @Test func mvRename() async throws {
        let r = try await onBoth("""
            touch old
            mv old new
            ls
            """)
        #expect(r.stdout == "new\n")
    }

    @Test func cpRecursive() async throws {
        let r = try await onBoth("""
            mkdir -p src/inner
            touch src/one src/inner/two
            cp -r src dup
            ls dup/inner
            """)
        #expect(r.stdout == "two\n")
    }

    // MARK: Redirection

    @Test func heredocPipedIntoFile() async throws {
        let r = try await onBoth("""
            cat <<EOF > note
            line1
            line2
            EOF
            cat note
            """)
        #expect(r.stdout == "line1\nline2\n")
    }

    @Test func forLoopRedirectedToFile() async throws {
        let r = try await onBoth("""
            for i in 1 2 3; do
              echo item-$i
            done > items
            cat items
            """)
        #expect(r.stdout == "item-1\nitem-2\nitem-3\n")
    }

    @Test func stderrSplitFromStdout() async throws {
        let r = try await onBoth("""
            cat missing 2> err
            cat err
            """)
        // "cat: missing: no such file or directory" text format is
        // slightly different on macOS vs our custom error, but both
        // backends should produce the *same* error text — that's the
        // portability claim under test.
        #expect(!r.stdout.isEmpty)
    }

    // MARK: Globbing

    @Test func globEcho() async throws {
        let r = try await onBoth("""
            touch a.txt b.txt c.md
            echo *.txt
            """)
        #expect(r.stdout == "a.txt b.txt\n")
    }

    @Test func globFeedsMultiArgCommand() async throws {
        let r = try await onBoth("""
            echo one > 1.txt
            echo two > 2.txt
            cat *.txt
            """)
        #expect(r.stdout == "one\ntwo\n")
    }

    // MARK: Tilde

    #if !os(Windows)
    @Test func tildeResolvesToHome() async throws {
        let r = try await onBoth("""
            echo hi > ~/greeting
            cat ~/greeting
            """)
        #expect(r.stdout == "hi\n")
    }
    #endif

    // MARK: Pipeline + redirection + globbing

    @Test func kitchenSink() async throws {
        let r = try await onBoth("""
            mkdir -p logs
            for i in 1 2 3 4 5; do
              echo "entry-$i" >> logs/out.txt
            done
            cat logs/*.txt | head -n 3
            """)
        #expect(r.stdout == "entry-1\nentry-2\nentry-3\n")
    }

    @Test func variablesSurvive() async throws {
        let r = try await onBoth("""
            NAME=world
            echo "hello $NAME" > out
            cat out
            """)
        #expect(r.stdout == "hello world\n")
    }
}
