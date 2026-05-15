import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct ReadCommandTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: Basic single-variable

    @Test func singleVariable() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("hello world\n")
        try await cap.shell.run("read line; echo \"[$line]\"")
        #expect(cap.stdout == "[hello world]\n")
    }

    @Test func noVariableUsesREPLY() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("captured\n")
        try await cap.shell.run("read; echo \"[$REPLY]\"")
        #expect(cap.stdout == "[captured]\n")
    }

    @Test func eofReturnsFailure() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("")
        try await cap.shell.run(#"""
            if read line; then echo got
            else echo eof
            fi
            """#)
        #expect(cap.stdout == "eof\n")
    }

    // MARK: Multi-variable splitting (default IFS)

    @Test func multipleVariables() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("first second third\n")
        try await cap.shell.run("""
            read a b c
            echo "[$a]"
            echo "[$b]"
            echo "[$c]"
            """)
        #expect(cap.stdout == "[first]\n[second]\n[third]\n")
    }

    @Test func lastVariableSoaksRemainder() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("first second third more stuff\n")
        try await cap.shell.run("""
            read a b c
            echo "[$a]"
            echo "[$b]"
            echo "[$c]"
            """)
        #expect(cap.stdout == "[first]\n[second]\n[third more stuff]\n")
    }

    @Test func extraVariablesEmpty() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("only\n")
        try await cap.shell.run("""
            read a b c
            echo "[$a][$b][$c]"
            """)
        #expect(cap.stdout == "[only][][]\n")
    }

    @Test func leadingWhitespaceTrimmedDefaultIFS() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("   spaced   value   \n")
        try await cap.shell.run("""
            read a b
            echo "[$a]"
            echo "[$b]"
            """)
        // Leading and trailing whitespace stripped; the rest preserved.
        #expect(cap.stdout == "[spaced]\n[value]\n")
    }

    // MARK: Custom IFS

    @Test func customIFSSplitsOnColon() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("a:b:c:d\n")
        try await cap.shell.run("""
            IFS=":" read a b c
            echo "$a $b $c"
            """)
        #expect(cap.stdout == "a b c:d\n")
    }

    // MARK: - r raw mode

    @Test func rawModePreservesBackslash() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string(#"with\backslash"# + "\n")
        try await cap.shell.run(#"""
            read -r line
            echo "[$line]"
            """#)
        #expect(cap.stdout == "[with\\backslash]\n")
    }

    @Test func defaultModeStripsBackslash() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string(#"with\backslash"# + "\n")
        try await cap.shell.run("""
            read line
            echo "[$line]"
            """)
        #expect(cap.stdout == "[withbackslash]\n")
    }

    // MARK: while read

    @Test func whileReadIteratesLines() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("alpha\nbravo\ncharlie\n")
        try await cap.shell.run("""
            while read l; do
              echo "[$l]"
            done
            """)
        #expect(cap.stdout == "[alpha]\n[bravo]\n[charlie]\n")
    }

    @Test func whileReadHandlesNoTrailingNewline() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("only-line")
        try await cap.shell.run("""
            while read l; do
              echo "[$l]"
            done
            """)
        #expect(cap.stdout == "[only-line]\n")
    }

    @Test func readsConsumeAcrossPipeline() async throws {
        // First read takes line 1, second read takes line 2.
        let cap = makeShell()
        cap.shell.stdin = .string("first\nsecond\nthird\n")
        try await cap.shell.run("""
            read a
            read b
            echo "a=$a b=$b"
            """)
        #expect(cap.stdout == "a=first b=second\n")
    }

    // MARK: - p prompt

    @Test func promptWritesToStderr() async throws {
        let cap = makeShell()
        cap.shell.stdin = .string("answer\n")
        try await cap.shell.run("""
            read -p "what? " name
            echo "got: $name"
            """)
        #expect(cap.stdout == "got: answer\n")
        #expect(cap.stderr == "what? ")
    }
}
