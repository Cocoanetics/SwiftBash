import XCTest
@testable import BashInterpreter

final class GlobMatcherTests: XCTestCase {

    private func m(_ pat: String, _ s: String) -> Bool {
        GlobMatcher.match(pattern: pat, string: s)
    }

    // MARK: Literals

    func testLiteralMatch()   { XCTAssertTrue(m("abc", "abc")) }
    func testLiteralMismatch() { XCTAssertFalse(m("abc", "abd")) }
    func testEmptyPatternMatchesEmpty()   { XCTAssertTrue(m("", "")) }
    func testEmptyPatternRejectsNonEmpty() { XCTAssertFalse(m("", "a")) }

    // MARK: Star

    func testStarMatchesEmpty()      { XCTAssertTrue(m("*", "")) }
    func testStarMatchesAnyString()  { XCTAssertTrue(m("*", "anything")) }
    func testStarPrefix()            { XCTAssertTrue(m("*.txt", "note.txt")) }
    func testStarPrefixMismatch()    { XCTAssertFalse(m("*.txt", "note.md")) }
    func testStarSuffix()            { XCTAssertTrue(m("log*", "logger")) }
    func testStarMiddle()            { XCTAssertTrue(m("a*c", "abbbc")) }
    func testStarDoubleMatches()     { XCTAssertTrue(m("a**b", "axxxb")) } // `**` collapses

    // MARK: Question mark

    func testQuestionMatchesOneChar()   { XCTAssertTrue(m("?", "a")) }
    func testQuestionRejectsEmpty()     { XCTAssertFalse(m("?", "")) }
    func testQuestionRejectsTwoChars()  { XCTAssertFalse(m("?", "ab")) }
    func testQuestionInContext()        { XCTAssertTrue(m("h?llo", "hello")) }

    // MARK: Character class

    func testCharClassMatches()         { XCTAssertTrue(m("[abc]", "b")) }
    func testCharClassRejects()         { XCTAssertFalse(m("[abc]", "d")) }
    func testCharClassRange()           { XCTAssertTrue(m("[a-z]", "m")) }
    func testCharClassRangeRejects()    { XCTAssertFalse(m("[a-z]", "M")) }
    func testCharClassNegation()        { XCTAssertTrue(m("[!abc]", "d")) }
    func testCharClassNegationRejects() { XCTAssertFalse(m("[!abc]", "b")) }
    func testCharClassCaretNegation()   { XCTAssertTrue(m("[^0-9]", "a")) }
    func testCharClassCombined()        { XCTAssertTrue(m("[A-Za-z0-9]", "z")) }

    // MARK: Escape

    func testEscapedStar() { XCTAssertTrue(m("\\*", "*")) }
    func testEscapedStarRejectsOther() { XCTAssertFalse(m("\\*", "a")) }
    func testEscapedQuestion() { XCTAssertTrue(m("\\?", "?")) }

    // MARK: Combinations

    func testMixed() {
        XCTAssertTrue(m("*.[ch]", "file.c"))
        XCTAssertTrue(m("*.[ch]", "file.h"))
        XCTAssertFalse(m("*.[ch]", "file.txt"))
    }

    func testPathLikePattern() {
        XCTAssertTrue(m("/usr/*/bin", "/usr/local/bin"))
        XCTAssertFalse(m("/usr/*/bin", "/usr/local/sbin"))
    }

    // MARK: Unmatched bracket → pattern treated as literal-ish; should not match
    func testUnmatchedBracketIsRejected() {
        XCTAssertFalse(m("[abc", "a"))
    }
}
