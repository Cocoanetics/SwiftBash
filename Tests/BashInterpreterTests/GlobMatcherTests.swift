import Testing
@testable import BashInterpreter

@Suite struct GlobMatcherTests {

    private func m(_ pat: String, _ s: String) -> Bool {
        GlobMatcher.match(pattern: pat, string: s)
    }

    // MARK: Literals

    @Test func literalMatch()               { #expect(m("abc", "abc")) }
    @Test func literalMismatch()            { #expect(!m("abc", "abd")) }
    @Test func emptyPatternMatchesEmpty()   { #expect(m("", "")) }
    @Test func emptyPatternRejectsNonEmpty() { #expect(!m("", "a")) }

    // MARK: Star

    @Test func starMatchesEmpty()     { #expect(m("*", "")) }
    @Test func starMatchesAnyString() { #expect(m("*", "anything")) }
    @Test func starPrefix()           { #expect(m("*.txt", "note.txt")) }
    @Test func starPrefixMismatch()   { #expect(!m("*.txt", "note.md")) }
    @Test func starSuffix()           { #expect(m("log*", "logger")) }
    @Test func starMiddle()           { #expect(m("a*c", "abbbc")) }
    @Test func starDoubleMatches()    { #expect(m("a**b", "axxxb")) } // `**` collapses

    // MARK: Question mark

    @Test func questionMatchesOneChar()  { #expect(m("?", "a")) }
    @Test func questionRejectsEmpty()    { #expect(!m("?", "")) }
    @Test func questionRejectsTwoChars() { #expect(!m("?", "ab")) }
    @Test func questionInContext()       { #expect(m("h?llo", "hello")) }

    // MARK: Character class

    @Test func charClassMatches()         { #expect(m("[abc]", "b")) }
    @Test func charClassRejects()         { #expect(!m("[abc]", "d")) }
    @Test func charClassRange()           { #expect(m("[a-z]", "m")) }
    @Test func charClassRangeRejects()    { #expect(!m("[a-z]", "M")) }
    @Test func charClassNegation()        { #expect(m("[!abc]", "d")) }
    @Test func charClassNegationRejects() { #expect(!m("[!abc]", "b")) }
    @Test func charClassCaretNegation()   { #expect(m("[^0-9]", "a")) }
    @Test func charClassCombined()        { #expect(m("[A-Za-z0-9]", "z")) }

    // MARK: Escape

    @Test func escapedStar()             { #expect(m("\\*", "*")) }
    @Test func escapedStarRejectsOther() { #expect(!m("\\*", "a")) }
    @Test func escapedQuestion()         { #expect(m("\\?", "?")) }

    // MARK: Combinations

    @Test func mixed() {
        #expect(m("*.[ch]", "file.c"))
        #expect(m("*.[ch]", "file.h"))
        #expect(!m("*.[ch]", "file.txt"))
    }

    @Test func pathLikePattern() {
        #expect(m("/usr/*/bin", "/usr/local/bin"))
        #expect(!m("/usr/*/bin", "/usr/local/sbin"))
    }

    // MARK: Unmatched bracket → pattern treated as literal-ish; should not match
    @Test func unmatchedBracketIsRejected() {
        #expect(!m("[abc", "a"))
    }
}
