import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct GlobMatcherTests {

    private func matches(_ pat: String, _ text: String) -> Bool {
        GlobMatcher.match(pattern: pat, string: text)
    }

    // MARK: Literals

    @Test func literalMatch() { #expect(matches("abc", "abc")) }
    @Test func literalMismatch() { #expect(!matches("abc", "abd")) }
    @Test func emptyPatternMatchesEmpty() { #expect(matches("", "")) }
    @Test func emptyPatternRejectsNonEmpty() { #expect(!matches("", "a")) }

    // MARK: Star

    @Test func starMatchesEmpty() { #expect(matches("*", "")) }
    @Test func starMatchesAnyString() { #expect(matches("*", "anything")) }
    @Test func starPrefix() { #expect(matches("*.txt", "note.txt")) }
    @Test func starPrefixMismatch() { #expect(!matches("*.txt", "note.md")) }
    @Test func starSuffix() { #expect(matches("log*", "logger")) }
    @Test func starMiddle() { #expect(matches("a*c", "abbbc")) }
    @Test func starDoubleMatches() { #expect(matches("a**b", "axxxb")) } // `**` collapses

    // MARK: Question mark

    @Test func questionMatchesOneChar() { #expect(matches("?", "a")) }
    @Test func questionRejectsEmpty() { #expect(!matches("?", "")) }
    @Test func questionRejectsTwoChars() { #expect(!matches("?", "ab")) }
    @Test func questionInContext() { #expect(matches("h?llo", "hello")) }

    // MARK: Character class

    @Test func charClassMatches() { #expect(matches("[abc]", "b")) }
    @Test func charClassRejects() { #expect(!matches("[abc]", "d")) }
    @Test func charClassRange() { #expect(matches("[a-z]", "m")) }
    @Test func charClassRangeRejects() { #expect(!matches("[a-z]", "M")) }
    @Test func charClassNegation() { #expect(matches("[!abc]", "d")) }
    @Test func charClassNegationRejects() { #expect(!matches("[!abc]", "b")) }
    @Test func charClassCaretNegation() { #expect(matches("[^0-9]", "a")) }
    @Test func charClassCombined() { #expect(matches("[A-Za-z0-9]", "z")) }

    // MARK: Escape

    @Test func escapedStar() { #expect(matches("\\*", "*")) }
    @Test func escapedStarRejectsOther() { #expect(!matches("\\*", "a")) }
    @Test func escapedQuestion() { #expect(matches("\\?", "?")) }

    // MARK: Combinations

    @Test func mixed() {
        #expect(matches("*.[ch]", "file.c"))
        #expect(matches("*.[ch]", "file.h"))
        #expect(!matches("*.[ch]", "file.txt"))
    }

    @Test func pathLikePattern() {
        #expect(matches("/usr/*/bin", "/usr/local/bin"))
        #expect(!matches("/usr/*/bin", "/usr/local/sbin"))
    }

    // MARK: Unmatched bracket → pattern treated as literal-ish; should not match
    @Test func unmatchedBracketIsRejected() {
        #expect(!matches("[abc", "a"))
    }
}
