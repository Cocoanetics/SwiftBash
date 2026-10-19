import Testing
import Foundation
@testable import BashInterpreter

/// `set -f` / `set -C`, the redirections bash scripts use (`&>`, `&>>`,
/// `>|`, closing an fd), and expansion before redirection. `set -f` and
/// `set -C` were rejected, and `&>`, `>|` and `N>&-` aborted the script
/// as unimplemented.
@Suite(.timeLimit(.minutes(1))) struct SetOptionsRedirectionTests {

    private func makeShell(files: [String] = []) async throws -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        try await cap.shell.fileSystem.createDirectory("/work", intermediates: true)
        cap.shell.environment.workingDirectory = "/work"
        for name in files {
            try await cap.shell.fileSystem.writeData(
                Data("\(name)\n".utf8), to: "/work/\(name)", append: false)
        }
        return cap
    }

    // MARK: set -f

    @Test func noglobTurnsOffPathnameExpansion() async throws {
        let cap = try await makeShell(files: ["a.txt", "b.txt"])
        try await cap.shell.run(#"""
            set -f; echo *.txt "$-"; set +f
            echo *.txt
            set -o noglob; echo *.txt; set +o noglob
            """#)
        #expect(cap.stdout == "*.txt fhB\na.txt b.txt\n*.txt\n")
    }

    // MARK: set -C and >|

    @Test func noclobberRefusesToOverwrite() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo one > keep
            set -C
            echo two > keep; echo "st=$? $-"
            echo two &> keep; echo "st=$?"
            echo appended >> keep
            echo forced >| keep
            echo new > fresh
            echo quiet > /dev/null
            set +C
            while read line; do echo "keep: $line"; done < keep
            read line < fresh; echo "fresh: $line"
            """#)
        #expect(cap.stdout == "st=1 hBC\nst=1\nkeep: forced\nfresh: new\n")
        #expect(cap.stderr.components(separatedBy: "keep: cannot overwrite existing file").count == 3)
    }

    @Test func aCompoundCommandsFailedRedirectFailsJustThatCommand() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo one > keep
            set -C
            { echo new; } > keep; echo "after group st=$?"
            ( echo x ) > /missing/dir/file; echo "after subshell st=$?"
            for i in 1; do echo loop; done > keep; echo "after loop st=$?"
            """#)
        #expect(cap.stdout == "after group st=1\nafter subshell st=1\nafter loop st=1\n")
        #expect(cap.stderr.contains("keep: cannot overwrite existing file"))
    }

    // MARK: &> and >&file

    @Test func bothStreamsToAFile() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            { echo out; echo err >&2; } &> both
            { echo more; echo again >&2; } &>> both
            { echo last; echo too >&2; } >& other
            while read line; do echo "both: $line"; done < both
            while read line; do echo "other: $line"; done < other
            """#)
        #expect(cap.stdout == """
            both: out
            both: err
            both: more
            both: again
            other: last
            other: too

            """)
        #expect(cap.stderr == "")
    }

    // MARK: Closing a descriptor

    @Test func closingADescriptorDropsWhatsWrittenToIt() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo gone 2>&- >&2
            read x <&-; echo "read st=$?"
            echo -n >&-; echo "empty st=$?"
            echo shown
            """#)
        #expect(cap.stdout == "read st=1\nempty st=0\nshown\n")
        #expect(cap.stderr == "")
    }

    /// Bash reports a write to a closed stdout and fails the command.
    @Test func writingToAClosedStdoutFails() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            echo hidden >&-; echo "st=$?"
            { printf a; pwd; } >&-; echo "st=$?"
            f() { echo in f; }; f >&-; echo "st=$?"
            x=$(echo sub >&-); echo "st=$? [$x]"
            """#)
        #expect(cap.stdout == "st=1\nst=1\nst=1\nst=1 []\n")
        #expect(cap.stderr == """
            swift-bash: line 1: echo: write error: Bad file descriptor
            swift-bash: line 2: printf: write error: Bad file descriptor
            swift-bash: line 2: pwd: write error: Bad file descriptor
            swift-bash: line 3: echo: write error: Bad file descriptor
            swift-bash: line 4: echo: write error: Bad file descriptor

            """)
    }

    // MARK: Order

    @Test func wordsExpandBeforeRedirection() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"echo * > out; read listed < out; echo "$listed""#)
        #expect(cap.stdout == "*\n")
    }

    @Test func xtraceQuotesLikeBashAndIgnoresTheCommandsRedirection() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            set -x
            echo "x y" "it's" plain '' 2>/dev/null >/dev/null
            set +x
            """#)
        #expect(cap.stderr == "+ echo 'x y' 'it'\\''s' plain ''\n+ set +x\n")
        #expect(Shell.xtraceWord("a=b") == "a=b")
        #expect(Shell.xtraceWord("~user") == "'~user'")
    }
}
