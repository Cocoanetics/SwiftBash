import XCTest
@testable import BashSyntax

final class SplitTests: XCTestCase {

    func testBasicSplit() async throws {
        XCTAssertEqual(try BashSyntax.split("a b c"), ["a", "b", "c"])
    }

    func testOperatorsAreEmittedLiterally() async throws {
        XCTAssertEqual(try BashSyntax.split("ls | grep foo && echo"),
                       ["ls", "|", "grep", "foo", "&&", "echo"])
    }

    func testSingleQuotesRemoved() async throws {
        XCTAssertEqual(try BashSyntax.split("echo 'hello world'"),
                       ["echo", "hello world"])
    }

    func testDoubleQuotesRemoved() async throws {
        XCTAssertEqual(try BashSyntax.split(#"echo "hello world""#),
                       ["echo", "hello world"])
    }

    func testAdjacentQuotedAndUnquotedConcatenate() async throws {
        XCTAssertEqual(try BashSyntax.split(#"foo"bar"'baz'"#), [#"foobarbaz"#])
    }

    func testCommandSubstitutionPreserved() async throws {
        XCTAssertEqual(try BashSyntax.split(#"echo $(date +%s)"#),
                       ["echo", "$(date +%s)"])
    }

    func testBackticksPreserved() async throws {
        XCTAssertEqual(try BashSyntax.split("echo `date +%s`"),
                       ["echo", "`date +%s`"])
    }

    func testProcessSubstitutionPreserved() async throws {
        XCTAssertEqual(try BashSyntax.split("diff <(a) <(b)"),
                       ["diff", "<(a)", "<(b)"])
    }

    func testNestedCommandSubstitution() async throws {
        XCTAssertEqual(try BashSyntax.split("echo $(echo $(echo deep))"),
                       ["echo", "$(echo $(echo deep))"])
    }

    func testSubstitutionInsideDoubleQuotes() async throws {
        XCTAssertEqual(try BashSyntax.split(#"echo "a $(b) c""#),
                       ["echo", "a $(b) c"])
    }

    func testSubstitutionInsideSingleQuotesIsLiteral() async throws {
        XCTAssertEqual(try BashSyntax.split(#"echo 'a $(b) c'"#),
                       ["echo", "a $(b) c"])
    }

    func testRedirectOperators() async throws {
        XCTAssertEqual(try BashSyntax.split("cat > out 2>&1"),
                       ["cat", ">", "out", "2", ">&", "1"])
    }

    func testAmpersandBackgroundedCommand() async throws {
        XCTAssertEqual(try BashSyntax.split("sleep 10 &"), ["sleep", "10", "&"])
    }
}
