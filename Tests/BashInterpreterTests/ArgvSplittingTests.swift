import Testing
@testable import BashInterpreter

/// Pinning the argv-level word-expansion semantics to bash's exact
/// rules: boundary merge for `"$@"`, IFS-splitting for unquoted
/// substitutions, explicit-empty preservation for `""`, and the
/// "unset substitution disappears" rule.
///
/// Each test uses a custom `args` command that records its argv so we
/// can assert on the exact list of arguments passed in.
@Suite struct ArgvSplittingTests {

    /// `args A B C` prints `[1]A\n[2]B\n[3]C\n` so a test can assert
    /// on exact split counts and contents.
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

    // MARK: "$@" boundary merge

    @Test func dollarAtQuotedSplitsParams() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["a", "b", "c"]
        try await cap.shell.run(#"args "$@""#)
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\ncount=3\n")
    }

    @Test func dollarAtQuotedPreservesEmbeddedSpaces() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["one two", "three"]
        try await cap.shell.run(#"args "$@""#)
        #expect(cap.stdout == "[1]one two\n[2]three\ncount=2\n")
    }

    @Test func dollarAtBoundaryMergeSingleParam() async throws {
        // Single param: prefix and suffix BOTH merge with it.
        let cap = makeShell()
        cap.shell.positionalParameters = ["X"]
        try await cap.shell.run(#"args "pre$@post""#)
        #expect(cap.stdout == "[1]preXpost\ncount=1\n")
    }

    @Test func dollarAtBoundaryMergeMultipleParams() async throws {
        // First merges with prefix, last with suffix, middle stand alone.
        let cap = makeShell()
        cap.shell.positionalParameters = ["a", "b", "c"]
        try await cap.shell.run(#"args "pre$@post""#)
        #expect(cap.stdout == "[1]prea\n[2]b\n[3]cpost\ncount=3\n")
    }

    @Test func dollarAtBoundaryMergeTwoParams() async throws {
        // No middle: prefix joins first, suffix joins last.
        let cap = makeShell()
        cap.shell.positionalParameters = ["a", "b"]
        try await cap.shell.run(#"args "pre$@post""#)
        #expect(cap.stdout == "[1]prea\n[2]bpost\ncount=2\n")
    }

    @Test func dollarAtEmptyParamsProducesZeroArgs() async throws {
        let cap = makeShell()
        // No positional params.
        try await cap.shell.run(#"args "$@""#)
        #expect(cap.stdout == "count=0\n")
    }

    @Test func dollarAtEmptyParamsBoundaryRejoins() async throws {
        // `"pre$@post"` with empty params → "prepost" (single arg).
        // The substitution disappears; the surrounding quoted text
        // reconnects.
        let cap = makeShell()
        try await cap.shell.run(#"args "pre$@post""#)
        #expect(cap.stdout == "[1]prepost\ncount=1\n")
    }

    @Test func dollarAtUnquotedAlsoSplits() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["a", "b", "c"]
        try await cap.shell.run("args $@")
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\ncount=3\n")
    }

    @Test func dollarAtUnquotedIFSSplitsValuesToo() async throws {
        // Unquoted $@ does field splitting on each value individually:
        // ["one two", "three"] becomes 3 args, not 2, because "one two"
        // splits on whitespace. This is exactly bash's `$@` rule.
        let cap = makeShell()
        cap.shell.positionalParameters = ["one two", "three"]
        try await cap.shell.run("args $@")
        #expect(cap.stdout == "[1]one\n[2]two\n[3]three\ncount=3\n")
    }

    // MARK: "$*" / $*

    @Test func dollarStarQuotedJoinsToSingleArg() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["a", "b", "c"]
        try await cap.shell.run(#"args "$*""#)
        #expect(cap.stdout == "[1]a b c\ncount=1\n")
    }

    @Test func dollarStarUnquotedSplitsLikeAt() async throws {
        // Unquoted $* joins by the first IFS char (space) then field-
        // splits on IFS, so the result is the same as unquoted $@ when
        // params don't have embedded whitespace.
        let cap = makeShell()
        cap.shell.positionalParameters = ["a", "b", "c"]
        try await cap.shell.run("args $*")
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\ncount=3\n")
    }

    // MARK: $VAR IFS splitting

    @Test func unquotedVarSplitsOnWhitespace() async throws {
        let cap = makeShell()
        cap.shell.environment["WORDS"] = "alpha bravo charlie"
        try await cap.shell.run("args $WORDS")
        #expect(cap.stdout == "[1]alpha\n[2]bravo\n[3]charlie\ncount=3\n")
    }

    @Test func quotedVarStaysSingleArg() async throws {
        let cap = makeShell()
        cap.shell.environment["WORDS"] = "alpha bravo charlie"
        try await cap.shell.run(#"args "$WORDS""#)
        #expect(cap.stdout == "[1]alpha bravo charlie\ncount=1\n")
    }

    @Test func unquotedVarMultipleSpaces() async throws {
        // Multiple consecutive whitespace chars produce no empty fields.
        let cap = makeShell()
        cap.shell.environment["WORDS"] = "a   b\t\tc\nd"
        try await cap.shell.run("args $WORDS")
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\n[4]d\ncount=4\n")
    }

    @Test func unquotedUnsetVarContributesZeroArgs() async throws {
        let cap = makeShell()
        try await cap.shell.run("args before $UNSET after")
        #expect(cap.stdout == "[1]before\n[2]after\ncount=2\n")
    }

    @Test func unquotedCommandSubSplits() async throws {
        let cap = makeShell()
        try await cap.shell.run("args $(echo a b c)")
        #expect(cap.stdout == "[1]a\n[2]b\n[3]c\ncount=3\n")
    }

    @Test func quotedCommandSubStaysSingleArg() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"args "$(echo a b c)""#)
        #expect(cap.stdout == "[1]a b c\ncount=1\n")
    }

    // MARK: Empty quoted preservation

    @Test func emptyDoubleQuotesPreserveOneEmptyArg() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"args "" foo"#)
        #expect(cap.stdout == "[1]\n[2]foo\ncount=2\n")
    }

    @Test func emptySingleQuotesPreserveOneEmptyArg() async throws {
        let cap = makeShell()
        try await cap.shell.run("args '' foo")
        #expect(cap.stdout == "[1]\n[2]foo\ncount=2\n")
    }

    @Test func quotedUnsetPreservesOneEmptyArg() async throws {
        // "$UNSET" is preserved as an empty arg (the quotes anchor it),
        // but bare $UNSET disappears entirely.
        let cap = makeShell()
        try await cap.shell.run(#"args "$UNSET" foo"#)
        #expect(cap.stdout == "[1]\n[2]foo\ncount=2\n")
    }

    // MARK: Mixed-quote concatenation

    @Test func adjacentQuotedSegmentsConcatenate() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "value"
        try await cap.shell.run(#"args "pre"'mid'$X"post""#)
        #expect(cap.stdout == "[1]premidvaluepost\ncount=1\n")
    }

    @Test func adjacentEmptyQuotesConcatenateAndPreserve() async throws {
        // `""''` is two adjacent empty quoted segments — still one
        // empty arg, not two.
        let cap = makeShell()
        try await cap.shell.run(#"args ""'' next"#)
        #expect(cap.stdout == "[1]\n[2]next\ncount=2\n")
    }

    // MARK: for-loop word splitting (uses the same machinery)

    @Test func forLoopOverQuotedDollarAtPreservesSpaces() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["one two", "three"]
        try await cap.shell.run(#"for x in "$@"; do echo [$x]; done"#)
        #expect(cap.stdout == "[one two]\n[three]\n")
    }

    @Test func forLoopOverUnquotedAtIFSSplitsValues() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["one two", "three"]
        try await cap.shell.run("for x in $@; do echo [$x]; done")
        #expect(cap.stdout == "[one]\n[two]\n[three]\n")
    }
}
