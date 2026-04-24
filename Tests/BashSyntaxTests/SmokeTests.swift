import Testing
@testable import BashSyntax

@Suite struct SmokeTests {

    @Test func parseSimpleCommand() throws {
        let parts = try BashSyntax.parse("echo hello")
        #expect(parts.count == 1)
        guard case .command(let children) = parts[0].kind else {
            Issue.record("expected CommandNode, got \(parts[0].kindName)")
            return
        }
        #expect(children.count == 2)
        #expect(children.map(\.kindName) == ["word", "word"])
        if case .word(let w, _) = children[0].kind { #expect(w == "echo") }
        if case .word(let w, _) = children[1].kind { #expect(w == "hello") }
    }

    @Test func splitHandlesProcessSubstitution() throws {
        let tokens = try BashSyntax.split(#"cat <(echo "a $(echo b)") | tee"#)
        #expect(tokens == ["cat", #"<(echo "a $(echo b)")"#, "|", "tee"])
    }

    @Test func splitRemovesQuotesLikeShlex() throws {
        // `a b"c"'d'` should concatenate the adjacent quoted/unquoted parts.
        let tokens = try BashSyntax.split(#"a b"c"'d'"#)
        #expect(tokens == ["a", "bcd"])
    }

    @Test func splitPreservesSubstitutionsInWords() throws {
        // Substitutions inside words stay as single tokens, with quotes removed
        // but `$(…)` / `` `…` `` preserved literally.
        let tokens = try BashSyntax.split(#"a "b $(c)" $(d) '$(e)'"#)
        #expect(tokens == ["a", "b $(c)", "$(d)", "$(e)"])
    }

    @Test func splitEmitsNewlineToken() throws {
        let tokens = try BashSyntax.split("a b\n")
        #expect(tokens == ["a", "b", "\n"])
    }

    @Test func topLevelAndAnd() throws {
        let node = try BashSyntax.parseSingle("true && cat <(echo $(echo foo))")
        guard case .list(let parts) = node.kind else {
            Issue.record("expected ListNode, got \(node.kindName)")
            return
        }
        #expect(parts.count == 3)
        #expect(parts.map(\.kindName) == ["command", "operator", "command"])
    }

    @Test func dumpContainsExpectedFragments() throws {
        let node = try BashSyntax.parseSingle("true && cat <(echo $(echo foo))")
        let dump = node.dump()
        // Spot-check key fragments to avoid whitespace brittleness.
        #expect(dump.hasPrefix("ListNode("), "\(dump)")
        #expect(dump.contains("OperatorNode(op='&&', pos=(5, 7))"), "\(dump)")
        #expect(dump.contains("WordNode(pos=(0, 4), word='true')"), "\(dump)")
        #expect(dump.contains("ProcesssubstitutionNode(command="), "\(dump)")
        #expect(dump.contains("CommandsubstitutionNode(command="), "\(dump)")
    }
}
