import XCTest
@testable import BashSyntax

final class ErrorTests: XCTestCase {

    func testUnterminatedDoubleQuoteThrows() {
        XCTAssertThrowsError(try BashSyntax.parse(#"echo "unterminated"#)) { err in
            guard let e = err as? BashSyntaxError,
                  case .parsing(let msg, _, _) = e
            else { return XCTFail("expected parsing error") }
            XCTAssertTrue(msg.contains("unexpected EOF"), msg)
        }
    }

    func testUnterminatedCommandSubstitutionThrows() {
        XCTAssertThrowsError(try BashSyntax.parse("echo $(true")) { err in
            guard let e = err as? BashSyntaxError,
                  case .parsing(let msg, _, _) = e
            else { return XCTFail("expected parsing error") }
            XCTAssertTrue(msg.contains("unexpected EOF"), msg)
        }
    }

    func testUnbalancedBraceThrows() {
        XCTAssertThrowsError(try BashSyntax.parse("{ echo;")) { err in
            XCTAssertTrue(err is BashSyntaxError)
        }
    }

    func testErrorCarriesPosition() {
        do {
            _ = try BashSyntax.parse("if true; then")
            XCTFail("expected throw")
        } catch let err as BashSyntaxError {
            XCTAssertNotNil(err.position)
            XCTAssertNotNil(err.source)
            XCTAssertEqual(err.source, "if true; then")
        } catch {
            XCTFail("expected BashSyntaxError")
        }
    }
}
