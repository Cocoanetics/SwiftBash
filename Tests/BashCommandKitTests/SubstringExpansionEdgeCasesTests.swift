import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Hardening pass for `${var:offset[:length]}` expansion. The body
/// can contain any of the bash expansion / quote / arithmetic forms,
/// and the field-separator `:` must only be recognised at the
/// outermost level. Each edge case below tests a specific nesting
/// form that previously would have broken a naive `split on the next
/// :` scanner.
@Suite(.timeLimit(.minutes(1))) struct SubstringExpansionEdgeCasesTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: - Quote regions

    @Test func singleQuotedColonIsLiteral() async throws {
        // The `:` inside `'a:b'` must not split the offset field.
        // `'a:b'` isn't valid arithmetic, so we expect a bash-
        // shaped diagnostic on stderr that references the FULL
        // quoted token (not a truncated `'a`) — proof that the
        // scanner kept the field together — and a non-success
        // exit via `ShellExit`.
        let cap = makeShell()
        let status = try await cap.shell.run(
            "text=hello; echo \"${text:'a:b':1}\"")
        #expect(!status.isSuccess)
        #expect(cap.stderr.contains("'a:b'"))
    }

    @Test func doubleQuotedColonIsLiteral() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run(
            "text=hello; echo \"${text:\"a:b\":1}\"")
        #expect(!status.isSuccess)
        // Inner `:` did not split — the diagnostic references the
        // full bracketed expression.
        #expect(cap.stderr.contains("a:b"))
    }

    // MARK: - Backslash escape

    @Test func backslashEscapedColonIsLiteral() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run(
            #"text=hello; echo "${text:\::1}""#)
        #expect(!status.isSuccess)
        // Critically: NOT a "malformed substring" — the scanner
        // captured `\:` as a single arithmetic token and handed it
        // to the arith evaluator, which rejected it as a value.
        #expect(!cap.stderr.contains("malformed substring"))
    }

    // MARK: - Command substitution inside the offset

    @Test func dollarParenInsideOffsetDoesNotSplit() async throws {
        // `${var:$(echo 1):2}` — the `:` after `echo` is INSIDE
        // `$( )` so it must not terminate the offset.
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; echo "${text:$(echo 1):2}""#)
        #expect(cap.stdout == "bc\n")
    }

    @Test func dollarParenWithColonContentInsideOffset() async throws {
        // The command substitution itself contains a `:` (a
        // colon-quoted echo). The scanner must walk into the $(...)
        // until the matching `)` and only then look for the field
        // separator.
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; echo "${text:$(echo 2 : 0 | cut -d' ' -f1):2}""#)
        #expect(cap.stdout == "cd\n")
    }

    // MARK: - Parameter expansion inside the offset

    @Test func nestedParameterExpansionInsideOffset() async throws {
        // `${text:${a:1:1}:2}` — inner substring expression's `:`
        // characters must not be confused with the outer ones.
        // Inner `${a:1:1}` on `a=xyz` is `y`, but as arithmetic
        // that's not numeric so we use a numeric helper. Instead
        // test with `${a:-2}` (default form, plain): the `:-` makes
        // bash treat the whole thing as default-value, not
        // substring. Use `${a:-2}` which evaluates to 2 when a is
        // unset, and the OUTER substring then has offset 2.
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; unset a; echo "${text:${a:-2}:2}""#)
        #expect(cap.stdout == "cd\n")
    }

    // MARK: - Arithmetic expansion inside the offset

    @Test func arithmeticExpansionInsideOffset() async throws {
        // `${var:$((i+1)):2}` — the `$((..))` has two `)`s in its
        // close. The scanner walks them as `$(` + `(` opens, then
        // `)` + `)` closes.
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; i=1; echo "${text:$((i+1)):2}""#)
        #expect(cap.stdout == "cd\n")
    }

    // MARK: - Ternary

    @Test func ternaryInOffsetBindsInnerColon() async throws {
        // `${text:i?2:4:2}` — `i?2:4` is the offset (ternary),
        // `2` is the length. The first `:` after `2` belongs to
        // the ternary, the second `:` is the field separator.
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; i=1; echo "${text:i?2:4:2}""#)
        // i=1 (truthy) → offset 2 → "cd".
        #expect(cap.stdout == "cd\n")
    }

    @Test func ternaryFalseBranch() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; i=0; echo "${text:i?2:4:2}""#)
        // i=0 (falsy) → offset 4 → "ef".
        #expect(cap.stdout == "ef\n")
    }

    @Test func nestedTernary() async throws {
        // `${text:i?(j?1:2):4:2}` — outer ternary on `i`, inner
        // on `j`. Inner `:` is consumed by inner `?`, outer `:` by
        // outer `?`. Third `:` is the field separator. The inner
        // ternary lives inside a `(...)` group so the paren-depth
        // protection ALSO needs to work.
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; i=1; j=0; echo "${text:i?(j?1:2):4:2}""#)
        // i=1 → take first ternary branch: (j?1:2). j=0 → 2.
        // offset=2 → "cd".
        #expect(cap.stdout == "cd\n")
    }

    // MARK: - Parens

    @Test func parensInOffset() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; echo "${text:(1+1):2}""#)
        #expect(cap.stdout == "cd\n")
    }

    @Test func nestedParens() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; echo "${text:((1+1)):2}""#)
        #expect(cap.stdout == "cd\n")
    }

    // MARK: - Length field can carry the same forms

    @Test func ternaryInLengthBindsInnerColon() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdefgh; n=1; echo "${text:1:n?3:5}""#)
        // n=1 → length 3 → "bcd".
        #expect(cap.stdout == "bcd\n")
    }

    @Test func dollarParenInLength() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; echo "${text:1:$(echo 3)}""#)
        #expect(cap.stdout == "bcd\n")
    }

    // MARK: - Empty / malformed fields

    @Test func emptyLengthIsError() async throws {
        // `${text:1:}` — bash rejects an empty length field. Should
        // emit a diagnostic and yield $? = 1 via `ShellExit`.
        let cap = makeShell()
        let status = try await cap.shell.run(
            #"text=abcdef; echo "${text:1:}""#)
        #expect(!status.isSuccess)
        #expect(cap.stderr.contains("malformed substring"))
    }

    @Test func emptyOffsetIsError() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run(
            #"text=abcdef; echo "${text::1}""#)
        #expect(!status.isSuccess)
        #expect(cap.stderr.contains("malformed substring"))
    }

    // MARK: - Whitespace and negative offsets

    @Test func leadingSpaceNegativeOffset() async throws {
        let cap = makeShell()
        // `${text: -2}` — bash's space-prefix to disambiguate from
        // default-value form. Take last 2 chars.
        try await cap.shell.run(#"text=abcdef; echo "${text: -2}""#)
        #expect(cap.stdout == "ef\n")
    }

    @Test func plainNumericOffsetAndLength() async throws {
        // Regression check that the scanner still handles the
        // simple case after all the depth tracking was added.
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; echo "${text:2:3}""#)
        #expect(cap.stdout == "cde\n")
    }

    @Test func offsetOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; echo "${text:3}""#)
        #expect(cap.stdout == "def\n")
    }
}
