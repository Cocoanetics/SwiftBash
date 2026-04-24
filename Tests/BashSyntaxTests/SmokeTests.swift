import XCTest
@testable import BashSyntax

final class SmokeTests: XCTestCase {

    func testParseSimpleCommand() throws {
        let parts = try BashSyntax.parse("echo hello")
        XCTAssertEqual(parts.count, 1)
        guard case .command(let children) = parts[0].kind else {
            return XCTFail("expected CommandNode, got \(parts[0].kindName)")
        }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.map(\.kindName), ["word", "word"])
        if case .word(let w, _) = children[0].kind { XCTAssertEqual(w, "echo") }
        if case .word(let w, _) = children[1].kind { XCTAssertEqual(w, "hello") }
    }

    func testSplitHandlesProcessSubstitution() throws {
        let tokens = try BashSyntax.split(#"cat <(echo "a $(echo b)") | tee"#)
        XCTAssertEqual(tokens, ["cat", #"<(echo "a $(echo b)")"#, "|", "tee"])
    }

    func testSplitRemovesQuotesLikeShlex() throws {
        // `a b"c"'d'` should concatenate the adjacent quoted/unquoted parts.
        let tokens = try BashSyntax.split(#"a b"c"'d'"#)
        XCTAssertEqual(tokens, ["a", "bcd"])
    }

    func testSplitPreservesSubstitutionsInWords() throws {
        // Substitutions inside words stay as single tokens, with quotes removed
        // but `$(…)` / `\`…\`` preserved literally.
        let tokens = try BashSyntax.split(#"a "b $(c)" $(d) '$(e)'"#)
        XCTAssertEqual(tokens, ["a", "b $(c)", "$(d)", "$(e)"])
    }

    func testSplitEmitsNewlineToken() throws {
        let tokens = try BashSyntax.split("a b\n")
        XCTAssertEqual(tokens, ["a", "b", "\n"])
    }

    func testTopLevelAndAnd() throws {
        let node = try BashSyntax.parseSingle("true && cat <(echo $(echo foo))")
        guard case .list(let parts) = node.kind else {
            return XCTFail("expected ListNode, got \(node.kindName)")
        }
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.map(\.kindName), ["command", "operator", "command"])
    }

    func testDumpContainsExpectedFragments() throws {
        let node = try BashSyntax.parseSingle("true && cat <(echo $(echo foo))")
        let dump = node.dump()
        // Spot-check key fragments to avoid whitespace brittleness.
        XCTAssertTrue(dump.hasPrefix("ListNode("), dump)
        XCTAssertTrue(dump.contains("OperatorNode(op='&&', pos=(5, 7))"), dump)
        XCTAssertTrue(dump.contains("WordNode(pos=(0, 4), word='true')"), dump)
        XCTAssertTrue(dump.contains("ProcesssubstitutionNode(command="), dump)
        XCTAssertTrue(dump.contains("CommandsubstitutionNode(command="), dump)
    }
}
