import XCTest
@testable import BashSyntax

final class SplitTests: XCTestCase {

    func testBasicSplit() throws {
        XCTAssertEqual(try BashSyntax.split("a b c"), ["a", "b", "c"])
    }

    func testOperatorsAreEmittedLiterally() throws {
        XCTAssertEqual(try BashSyntax.split("ls | grep foo && echo"),
                       ["ls", "|", "grep", "foo", "&&", "echo"])
    }

    func testSingleQuotesRemoved() throws {
        XCTAssertEqual(try BashSyntax.split("echo 'hello world'"),
                       ["echo", "hello world"])
    }

    func testDoubleQuotesRemoved() throws {
        XCTAssertEqual(try BashSyntax.split(#"echo "hello world""#),
                       ["echo", "hello world"])
    }

    func testAdjacentQuotedAndUnquotedConcatenate() throws {
        XCTAssertEqual(try BashSyntax.split(#"foo"bar"'baz'"#), [#"foobarbaz"#])
    }

    func testCommandSubstitutionPreserved() throws {
        XCTAssertEqual(try BashSyntax.split(#"echo $(date +%s)"#),
                       ["echo", "$(date +%s)"])
    }

    func testBackticksPreserved() throws {
        XCTAssertEqual(try BashSyntax.split("echo `date +%s`"),
                       ["echo", "`date +%s`"])
    }

    func testProcessSubstitutionPreserved() throws {
        XCTAssertEqual(try BashSyntax.split("diff <(a) <(b)"),
                       ["diff", "<(a)", "<(b)"])
    }

    func testNestedCommandSubstitution() throws {
        XCTAssertEqual(try BashSyntax.split("echo $(echo $(echo deep))"),
                       ["echo", "$(echo $(echo deep))"])
    }

    func testSubstitutionInsideDoubleQuotes() throws {
        XCTAssertEqual(try BashSyntax.split(#"echo "a $(b) c""#),
                       ["echo", "a $(b) c"])
    }

    func testSubstitutionInsideSingleQuotesIsLiteral() throws {
        XCTAssertEqual(try BashSyntax.split(#"echo 'a $(b) c'"#),
                       ["echo", "a $(b) c"])
    }

    func testRedirectOperators() throws {
        XCTAssertEqual(try BashSyntax.split("cat > out 2>&1"),
                       ["cat", ">", "out", "2", ">&", "1"])
    }

    func testAmpersandBackgroundedCommand() throws {
        XCTAssertEqual(try BashSyntax.split("sleep 10 &"), ["sleep", "10", "&"])
    }
}
