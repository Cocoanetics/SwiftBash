import XCTest
@testable import BashSyntax

final class HeredocTests: XCTestCase {

    func testHeredocRedirectParses() async throws {
        let src = "cat <<EOF\nhello\nEOF\n"
        let parts = try BashSyntax.parse(src)
        XCTAssertEqual(parts.count, 1)
        guard case .command(let children) = parts[0].kind,
              let redir = children.last,
              case .redirect(_, let type, let output, _) = redir.kind
        else { return XCTFail("expected command with redirect") }
        XCTAssertEqual(type, "<<")
        if case .word(let w, _) = output.kind {
            XCTAssertEqual(w, "EOF")
        }
    }

    func testHeredocBodyIsAttached() async throws {
        let src = "cat <<EOF\nhello\nworld\nEOF\n"
        let parts = try BashSyntax.parse(src)
        guard case .command(let children) = parts[0].kind,
              let redir = children.last,
              case .redirect(_, _, _, let heredoc) = redir.kind,
              let heredocNode = heredoc,
              case .heredoc(let body) = heredocNode.kind
        else { return XCTFail("expected heredoc body attached") }
        XCTAssertEqual(body, "hello\nworld\n")
    }

    func testHeredocThenAnotherCommand() async throws {
        let src = "cat <<A\nbody\nA\necho done\n"
        let parts = try BashSyntax.parse(src)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.last?.kindName, "command")
    }
}
