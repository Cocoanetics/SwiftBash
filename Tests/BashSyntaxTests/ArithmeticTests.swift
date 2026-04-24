import XCTest
@testable import BashSyntax

final class ArithmeticTests: XCTestCase {

    // MARK: Standalone `((…))`

    func testArithCommandAtCommandPosition() async throws {
        let node = try BashSyntax.parseSingle("(( x = 1 + 2 ))")
        guard case .compound(let list, _) = node.kind,
              let first = list.first,
              case .arithmeticCommand(let expr) = first.kind
        else { return XCTFail("expected compound(arithmeticCommand), got \(node.kindName)") }
        XCTAssertEqual(expr, " x = 1 + 2 ")
    }

    func testArithCommandTightNoSpaces() async throws {
        let node = try BashSyntax.parseSingle("((0))")
        guard case .compound(let list, _) = node.kind,
              case .arithmeticCommand(let expr) = list.first?.kind
        else { return XCTFail() }
        XCTAssertEqual(expr, "0")
    }

    func testArithCommandWithNestedParens() async throws {
        let node = try BashSyntax.parseSingle("(( (a + b) * c ))")
        guard case .compound(let list, _) = node.kind,
              case .arithmeticCommand(let expr) = list.first?.kind
        else { return XCTFail() }
        XCTAssertEqual(expr, " (a + b) * c ")
    }

    func testArithCommandInList() async throws {
        let node = try BashSyntax.parseSingle("true && ((x < 5))")
        guard case .list(let parts) = node.kind else { return XCTFail() }
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.last?.kindName, "compound")
        if case .compound(let list, _) = parts.last!.kind,
           case .arithmeticCommand(let expr) = list.first?.kind
        {
            XCTAssertEqual(expr, "x < 5")
        } else {
            XCTFail("expected arith command as last list part")
        }
    }

    func testArithCommandWithRedirection() async throws {
        let node = try BashSyntax.parseSingle("((x = 1)) > /tmp/out")
        guard case .compound(_, let redirects) = node.kind,
              let redir = redirects.first,
              case .redirect(_, let type, _, _) = redir.kind
        else { return XCTFail("expected compound with redirect") }
        XCTAssertEqual(type, ">")
    }

    // MARK: `$((…))` substitution

    func testArithSubstitutionInWord() async throws {
        let node = try BashSyntax.parseSingle("echo $((1 + 2 * 3))")
        guard case .command(let cparts) = node.kind,
              case .word(_, let wordParts) = cparts[1].kind,
              let first = wordParts.first,
              case .arithmeticSubstitution(let expr) = first.kind
        else { return XCTFail("expected arithmeticSubstitution inside word") }
        XCTAssertEqual(expr, "1 + 2 * 3")
    }

    func testArithSubstitutionRangeMapsToSource() async throws {
        let src = "echo $((1+2))"
        let node = try BashSyntax.parseSingle(src)
        guard case .command(let cparts) = node.kind,
              case .word(_, let wordParts) = cparts[1].kind,
              let arith = wordParts.first,
              case .arithmeticSubstitution = arith.kind
        else { return XCTFail() }
        XCTAssertEqual(arith.source(from: src), "$((1+2))")
    }

    func testNestedArithmeticSubstitution() async throws {
        let node = try BashSyntax.parseSingle("echo $(( $((1)) + 2 ))")
        guard case .command(let cparts) = node.kind,
              case .word(_, let wordParts) = cparts[1].kind,
              case .arithmeticSubstitution(let expr) = wordParts.first?.kind
        else { return XCTFail() }
        XCTAssertEqual(expr, " $((1)) + 2 ")
    }

    // MARK: Non-regressions

    func testSubshellInsideSubshellStillWorks() async throws {
        // Space between the parens keeps it a nested subshell, not arithmetic.
        let node = try BashSyntax.parseSingle("( (true) )")
        // Outer compound containing reserved ( / inner compound / reserved )
        guard case .compound(let list, _) = node.kind else {
            return XCTFail("expected compound, got \(node.kindName)")
        }
        // At least one of the inner items should itself be a compound (the
        // inner subshell) — not an arithmeticCommand.
        let hasInnerSubshell = list.contains { n in
            if case .compound(_, _) = n.kind { return true }
            return false
        }
        XCTAssertTrue(hasInnerSubshell, "inner subshell should remain a compound")
    }

    func testBareSubshellStillWorks() async throws {
        let node = try BashSyntax.parseSingle("(true)")
        guard case .compound(let list, _) = node.kind else { return XCTFail() }
        XCTAssertTrue(list.contains { $0.kindName == "command" })
    }

    // MARK: Errors

    func testUnclosedArithCommandThrows() async {
        XCTAssertThrowsError(try BashSyntax.parseSingle("(( 1 + 2")) { err in
            XCTAssertTrue(err is BashSyntaxError)
        }
    }

    func testUnclosedArithSubstitutionThrows() async {
        XCTAssertThrowsError(try BashSyntax.parseSingle("echo $((1+2")) { err in
            XCTAssertTrue(err is BashSyntaxError)
        }
    }
}
