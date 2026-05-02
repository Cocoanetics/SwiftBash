import Testing
@testable import BashSyntax

@Suite(.timeLimit(.minutes(1))) struct ArithmeticTests {

    // MARK: Standalone `((…))`

    @Test func arithCommandAtCommandPosition() throws {
        let node = try BashSyntax.parseSingle("(( x = 1 + 2 ))")
        guard case .compound(let list, _) = node.kind,
              let first = list.first,
              case .arithmeticCommand(let expr) = first.kind
        else {
            Issue.record("expected compound(arithmeticCommand), got \(node.kindName)")
            return
        }
        #expect(expr == " x = 1 + 2 ")
    }

    @Test func arithCommandTightNoSpaces() throws {
        let node = try BashSyntax.parseSingle("((0))")
        guard case .compound(let list, _) = node.kind,
              case .arithmeticCommand(let expr) = list.first?.kind
        else {
            Issue.record("expected arithmeticCommand")
            return
        }
        #expect(expr == "0")
    }

    @Test func arithCommandWithNestedParens() throws {
        let node = try BashSyntax.parseSingle("(( (a + b) * c ))")
        guard case .compound(let list, _) = node.kind,
              case .arithmeticCommand(let expr) = list.first?.kind
        else {
            Issue.record("expected arithmeticCommand")
            return
        }
        #expect(expr == " (a + b) * c ")
    }

    @Test func arithCommandInList() throws {
        let node = try BashSyntax.parseSingle("true && ((x < 5))")
        guard case .list(let parts) = node.kind else {
            Issue.record("expected list")
            return
        }
        #expect(parts.count == 3)
        #expect(parts.last?.kindName == "compound")
        if case .compound(let list, _) = parts.last!.kind,
           case .arithmeticCommand(let expr) = list.first?.kind
        {
            #expect(expr == "x < 5")
        } else {
            Issue.record("expected arith command as last list part")
        }
    }

    @Test func arithCommandWithRedirection() throws {
        let node = try BashSyntax.parseSingle("((x = 1)) > /tmp/out")
        guard case .compound(_, let redirects) = node.kind,
              let redir = redirects.first,
              case .redirect(_, let type, _, _) = redir.kind
        else {
            Issue.record("expected compound with redirect")
            return
        }
        #expect(type == ">")
    }

    // MARK: `$((…))` substitution

    @Test func arithSubstitutionInWord() throws {
        let node = try BashSyntax.parseSingle("echo $((1 + 2 * 3))")
        guard case .command(let cparts) = node.kind,
              case .word(_, let wordParts) = cparts[1].kind,
              let first = wordParts.first,
              case .arithmeticSubstitution(let expr) = first.kind
        else {
            Issue.record("expected arithmeticSubstitution inside word")
            return
        }
        #expect(expr == "1 + 2 * 3")
    }

    @Test func arithSubstitutionRangeMapsToSource() throws {
        let src = "echo $((1+2))"
        let node = try BashSyntax.parseSingle(src)
        guard case .command(let cparts) = node.kind,
              case .word(_, let wordParts) = cparts[1].kind,
              let arith = wordParts.first,
              case .arithmeticSubstitution = arith.kind
        else {
            Issue.record("expected arithmeticSubstitution")
            return
        }
        #expect(arith.source(from: src) == "$((1+2))")
    }

    @Test func nestedArithmeticSubstitution() throws {
        let node = try BashSyntax.parseSingle("echo $(( $((1)) + 2 ))")
        guard case .command(let cparts) = node.kind,
              case .word(_, let wordParts) = cparts[1].kind,
              case .arithmeticSubstitution(let expr) = wordParts.first?.kind
        else {
            Issue.record("expected arithmeticSubstitution")
            return
        }
        #expect(expr == " $((1)) + 2 ")
    }

    // MARK: Non-regressions

    @Test func subshellInsideSubshellStillWorks() throws {
        // Space between the parens keeps it a nested subshell, not arithmetic.
        let node = try BashSyntax.parseSingle("( (true) )")
        // Outer compound containing reserved ( / inner compound / reserved )
        guard case .compound(let list, _) = node.kind else {
            Issue.record("expected compound, got \(node.kindName)")
            return
        }
        // At least one of the inner items should itself be a compound (the
        // inner subshell) — not an arithmeticCommand.
        let hasInnerSubshell = list.contains { n in
            if case .compound(_, _) = n.kind { return true }
            return false
        }
        #expect(hasInnerSubshell, "inner subshell should remain a compound")
    }

    @Test func bareSubshellStillWorks() throws {
        let node = try BashSyntax.parseSingle("(true)")
        guard case .compound(let list, _) = node.kind else {
            Issue.record("expected compound")
            return
        }
        #expect(list.contains { $0.kindName == "command" })
    }

    // MARK: Errors

    @Test func unclosedArithCommandThrows() {
        #expect(throws: BashSyntaxError.self) {
            try BashSyntax.parseSingle("(( 1 + 2")
        }
    }

    @Test func unclosedArithSubstitutionThrows() {
        #expect(throws: BashSyntaxError.self) {
            try BashSyntax.parseSingle("echo $((1+2")
        }
    }
}
