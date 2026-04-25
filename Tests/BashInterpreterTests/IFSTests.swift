import Testing
@testable import BashInterpreter

/// Pin the `$IFS`-driven word-splitting rules.
@Suite struct IFSTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(name: "args") { argv, shell in
            for (i, a) in argv.dropFirst().enumerated() {
                shell.stdout("[\(i + 1)]\(a)\n")
            }
            shell.stdout("count=\(argv.count - 1)\n")
            return .success
        }
        return cap
    }

    // MARK: Default IFS (whitespace only)

    @Test func defaultIFSCollapsesRunsOfWhitespace() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "a   b\t\tc\nd"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\n[4]d\ncount=4\n")
    }

    @Test func defaultIFSStripsLeadingTrailingWhitespace() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "   a b   "
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a\n[2]b\ncount=2\n")
    }

    // MARK: IFS=":"

    @Test func colonIFSSplitsOnEachColon() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.environment["X"] = "a:b:c"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\ncount=3\n")
    }

    @Test func colonIFSPreservesEmptyFieldBetweenSeparators() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.environment["X"] = "a::b"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a\n[2]\n[3]b\ncount=3\n")
    }

    @Test func colonIFSLeadingSeparatorEmitsEmptyField() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.environment["X"] = ":a"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]\n[2]a\ncount=2\n")
    }

    @Test func colonIFSTrailingSeparatorDoesNotAddEmptyField() async throws {
        // Bash: `IFS=":" X="a:" set -- $X` → 1 arg ("a"), trailing
        // colon does NOT yield a third empty field.
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.environment["X"] = "a:"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a\ncount=1\n")
    }

    @Test func colonIFSDoesNotSplitOnSpace() async throws {
        // With IFS=":" only, spaces are kept inside fields.
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.environment["X"] = "a b:c d"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a b\n[2]c d\ncount=2\n")
    }

    // MARK: Mixed IFS=" :"

    @Test func mixedIFSAbsorbsWhitespaceAroundHardSep() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = " :"
        cap.shell.environment["X"] = "a : b"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a\n[2]b\ncount=2\n")
    }

    @Test func mixedIFSEmptyFieldFromConsecutiveHardSeps() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = " :"
        cap.shell.environment["X"] = "a::b"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a\n[2]\n[3]b\ncount=3\n")
    }

    @Test func mixedIFSWhitespaceCollapses() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = " :"
        cap.shell.environment["X"] = "a   b"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a\n[2]b\ncount=2\n")
    }

    // MARK: IFS=""

    @Test func emptyIFSDisablesSplitting() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ""
        cap.shell.environment["X"] = "a b c"
        try await cap.shell.run("args $X")
        #expect(cap.stdout == "[1]a b c\ncount=1\n")
    }

    // MARK: $* honors IFS for joining

    @Test func dollarStarQuotedJoinsOnIFSFirstChar() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.positionalParameters = ["a", "b", "c"]
        try await cap.shell.run(#"args "$*""#)
        #expect(cap.stdout == "[1]a:b:c\ncount=1\n")
    }

    @Test func dollarStarUnquotedSplitsBackToFields() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.positionalParameters = ["a", "b", "c"]
        try await cap.shell.run("args $*")
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\ncount=3\n")
    }

    // MARK: $@ ignores IFS for joining (each param is a field)

    @Test func dollarAtQuotedIgnoresIFSValue() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.positionalParameters = ["one two", "three"]
        try await cap.shell.run(#"args "$@""#)
        // "$@" emits each param verbatim — IFS doesn't change that.
        #expect(cap.stdout == "[1]one two\n[2]three\ncount=2\n")
    }

    @Test func dollarAtUnquotedSplitsEachParamWithIFS() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.positionalParameters = ["a:b", "c:d"]
        try await cap.shell.run("args $@")
        // Each param is IFS-split: "a:b" → [a, b], "c:d" → [c, d].
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\n[4]d\ncount=4\n")
    }

    // MARK: For-loop uses the same machinery

    @Test func forLoopUsesIFS() async throws {
        let cap = CapturingShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.environment["X"] = "alpha:bravo:charlie"
        try await cap.shell.run("for x in $X; do echo [$x]; done")
        #expect(cap.stdout == "[alpha]\n[bravo]\n[charlie]\n")
    }

    // MARK: Per-shell-invocation IFS

    @Test func ifsScopedAssignmentApplies() async throws {
        // `IFS=":" cmd $X` should split using the per-invocation IFS.
        let cap = makeShell()
        cap.shell.environment["X"] = "a:b:c"
        try await cap.shell.run(#"IFS=":" args $X"#)
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\ncount=3\n")
    }
}
