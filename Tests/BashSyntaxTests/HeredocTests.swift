import Testing
@testable import BashSyntax

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct HeredocTests {

    @Test func heredocRedirectParses() throws {
        let src = "cat <<EOF\nhello\nEOF\n"
        let parts = try BashSyntax.parse(src)
        #expect(parts.count == 1)
        guard case .command(let children) = parts[0].kind,
              let redir = children.last,
              case .redirect(_, let type, let output, _) = redir.kind
        else {
            Issue.record("expected command with redirect")
            return
        }
        #expect(type == "<<")
        if case .word(let w, _) = output.kind {
            #expect(w == "EOF")
        }
    }

    @Test func heredocBodyIsAttached() throws {
        let src = "cat <<EOF\nhello\nworld\nEOF\n"
        let parts = try BashSyntax.parse(src)
        guard case .command(let children) = parts[0].kind,
              let redir = children.last,
              case .redirect(_, _, _, let heredoc) = redir.kind,
              let heredocNode = heredoc,
              case .heredoc(let body) = heredocNode.kind
        else {
            Issue.record("expected heredoc body attached")
            return
        }
        #expect(body == "hello\nworld\n")
    }

    @Test func heredocThenAnotherCommand() throws {
        let src = "cat <<A\nbody\nA\necho done\n"
        let parts = try BashSyntax.parse(src)
        #expect(parts.count == 2)
        #expect(parts.last?.kindName == "command")
    }
}
#endif
