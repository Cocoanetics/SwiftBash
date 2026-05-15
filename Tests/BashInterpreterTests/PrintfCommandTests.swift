import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct PrintfCommandTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: Basics

    @Test func plainStringNoNewline() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "hello""#)
        #expect(cap.stdout == "hello")
    }

    @Test func backslashNewlineExpands() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "hello\n""#)
        #expect(cap.stdout == "hello\n")
    }

    @Test func tabAndCarriageReturn() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "a\tb\rc""#)
        #expect(cap.stdout == "a\tb\rc")
    }

    @Test func backslashLiteral() async throws {
        // Bash dquote: `\\` → `\`. Then printf sees `a\\b` only when we
        // double-escape the source (`\\\\`). Single-quoted form is the
        // simplest way to feed printf a literal `\\` to expand.
        let cap = makeShell()
        try await cap.shell.run(#"printf 'a\\b'"#)
        #expect(cap.stdout == "a\\b")
    }

    // MARK: %s

    @Test func percentS() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "[%s]\n" hello"#)
        #expect(cap.stdout == "[hello]\n")
    }

    @Test func percentSReusesFormat() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%s\n" a b c"#)
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func percentSWidthRightAlign() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "[%10s]" hi"#)
        #expect(cap.stdout == "[        hi]")
    }

    @Test func percentSWidthLeftAlign() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "[%-10s]" hi"#)
        #expect(cap.stdout == "[hi        ]")
    }

    @Test func percentSPrecisionTruncates() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "[%.3s]" abcdef"#)
        #expect(cap.stdout == "[abc]")
    }

    @Test func percentSStarWidthFromArg() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "[%*s]" 6 hi"#)
        #expect(cap.stdout == "[    hi]")
    }

    // MARK: %d / %i

    @Test func percentDPrintsInteger() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%d\n" 42"#)
        #expect(cap.stdout == "42\n")
    }

    @Test func percentDNegative() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%d\n" -42"#)
        #expect(cap.stdout == "-42\n")
    }

    @Test func percentDPlusFlagAddsSign() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%+d\n" 42"#)
        #expect(cap.stdout == "+42\n")
    }

    @Test func percentDSpaceFlagAddsSpace() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "% d\n" 42"#)
        #expect(cap.stdout == " 42\n")
    }

    @Test func percentDZeroPad() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%05d" 42"#)
        #expect(cap.stdout == "00042")
    }

    @Test func percentDPrecisionMinDigits() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%.5d" 42"#)
        #expect(cap.stdout == "00042")
    }

    @Test func percentDInvalidArgZero() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%d" """#)
        #expect(cap.stdout == "0")
    }

    @Test func percentDQuoteCharCode() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%d" "'A""#)
        #expect(cap.stdout == "65")
    }

    // MARK: %x / %o

    @Test func percentXLower() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%x" 255"#)
        #expect(cap.stdout == "ff")
    }

    @Test func percentXUpper() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%X" 255"#)
        #expect(cap.stdout == "FF")
    }

    @Test func percentXAlt() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%#x" 255"#)
        #expect(cap.stdout == "0xff")
    }

    @Test func percentO() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%o" 8"#)
        #expect(cap.stdout == "10")
    }

    // MARK: %c

    @Test func percentCFirstChar() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%c" hello"#)
        #expect(cap.stdout == "h")
    }

    // MARK: %%

    @Test func percentPercentLiteral() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "100%%\n""#)
        #expect(cap.stdout == "100%\n")
    }

    // MARK: %b

    @Test func percentBProcessesEscapes() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%b\n" "a\tb""#)
        #expect(cap.stdout == "a\tb\n")
    }

    @Test func percentBStopsOnBackslashC() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%b after" "before\cTRIM""#)
        #expect(cap.stdout == "before after")
    }

    // MARK: %q

    @Test func percentQSimple() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%q" hello"#)
        #expect(cap.stdout == "hello")
    }

    @Test func percentQWithSpace() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%q" "hello world""#)
        #expect(cap.stdout == "'hello world'")
    }

    @Test func percentQEmpty() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%q" """#)
        #expect(cap.stdout == "''")
    }

    @Test func percentQEscapesQuote() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%q" "it's""#)
        #expect(cap.stdout == #"'it'\''s'"#)
    }

    // MARK: %f / %e / %g

    @Test func percentF() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%f\n" 3.14"#)
        #expect(cap.stdout == "3.140000\n")
    }

    @Test func percentFPrecision() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%.2f" 3.14159"#)
        #expect(cap.stdout == "3.14")
    }

    @Test func percentG() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%g" 0.0001"#)
        #expect(cap.stdout == "0.0001")
    }

    // MARK: - v VAR

    @Test func dashVAssigns() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            printf -v out "[%s]" hello
            echo "$out"
            """#)
        #expect(cap.stdout == "[hello]\n")
    }

    @Test func dashVNoStdoutOutput() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf -v out "x""#)
        #expect(cap.stdout == "")
    }

    // MARK: Format reuse drains args

    @Test func twoDirectivesReusedAcrossArgs() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%s=%s\n" a 1 b 2"#)
        #expect(cap.stdout == "a=1\nb=2\n")
    }

    @Test func extraArgsForLiteralFormatIgnored() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "hello\n" extra args"#)
        #expect(cap.stdout == "hello\n")
    }

    // MARK: Octal / hex backslash escapes

    @Test func backslashOctalEscape() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "\0101""#)
        #expect(cap.stdout == "A")
    }

    @Test func backslashHexEscape() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "\x41""#)
        #expect(cap.stdout == "A")
    }

    // MARK: Smoke — common scripted patterns

    @Test func hexDumpStyleLine() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf "%02x %02x %02x\n" 1 2 255"#)
        #expect(cap.stdout == "01 02 ff\n")
    }

    @Test func nameValuePairs() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            for kv in name=ada role=admin; do
              printf "%s\n" "$kv"
            done
            """#)
        #expect(cap.stdout == "name=ada\nrole=admin\n")
    }
}
