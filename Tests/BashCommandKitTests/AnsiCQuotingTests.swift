import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Coverage for bash's `$'…'` ANSI-C quoting. The body's backslash
/// escapes (`\033`, `\e`, `\n`, `\xHH`, `\uHHHH`, etc.) expand to
/// the corresponding bytes — needed for the canonical
/// `esc=$'\033'` colour-script idiom.
@Suite(.timeLimit(.minutes(1))) struct AnsiCQuotingTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: - Both expansion paths

    @Test func octalEscapeInCommandArg() async throws {
        // Command-argument path (`Shell+Expansion+Argv.swift`).
        let cap = makeShell()
        try await cap.shell.run(#"printf '%s' $'\033'"#)
        #expect(cap.stdout == "\u{1B}")
    }

    @Test func octalEscapeInAssignment() async throws {
        // Assignment-value path (`Shell+Expansion.swift`). This is
        // the form the user's colour-gating idiom uses.
        let cap = makeShell()
        try await cap.shell.run(#"esc=$'\033'; printf '%s' "$esc""#)
        #expect(cap.stdout == "\u{1B}")
    }

    // MARK: - Individual escape sequences

    @Test func escapeAlias() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"x=$'\e'; printf '%s' "$x""#)
        #expect(cap.stdout == "\u{1B}")
    }

    @Test func newlineAndTab() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"x=$'a\tb\nc'; printf '%s' "$x""#)
        #expect(cap.stdout == "a\tb\nc")
    }

    @Test func hexEscape() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"x=$'\x41\x42'; printf '%s' "$x""#)
        #expect(cap.stdout == "AB")
    }

    @Test func unicodeEscape() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"x=$'é'; printf '%s' "$x""#)
        #expect(cap.stdout == "é")
    }

    @Test func longUnicodeEscape() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"x=$'\U0001F600'; printf '%s' "$x""#)
        #expect(cap.stdout == "😀")
    }

    @Test func controlEscape() async throws {
        let cap = makeShell()
        // `\cA` → 0x01 (Ctrl-A).
        try await cap.shell.run(#"x=$'\cA'; printf '%s' "$x""#)
        #expect(cap.stdout == "\u{01}")
    }

    @Test func escapedQuote() async throws {
        let cap = makeShell()
        // `\'` inside `$'…'` is a literal `'` and must NOT close
        // the quote.
        try await cap.shell.run(#"x=$'a\'b'; printf '%s' "$x""#)
        #expect(cap.stdout == "a'b")
    }

    @Test func backslashBackslash() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"x=$'a\\b'; printf '%s' "$x""#)
        #expect(cap.stdout == #"a\b"#)
    }

    // MARK: - Real-world combined sequence

    @Test func fullAnsiColorSequence() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            esc=$'\033'
            red="${esc}[31m"
            reset="${esc}[0m"
            printf '%shi%s' "$red" "$reset"
            """#)
        #expect(cap.stdout == "\u{1B}[31mhi\u{1B}[0m")
    }

    @Test func plainSingleQuoteStillLiteral() async throws {
        // Regression: a plain `'…'` (no leading `$`) must NOT
        // decode escapes. `'\033'` should produce the four literal
        // chars `\`, `0`, `3`, `3`.
        let cap = makeShell()
        try await cap.shell.run(#"x='\033'; printf '%s' "$x""#)
        #expect(cap.stdout == #"\033"#)
    }
}
