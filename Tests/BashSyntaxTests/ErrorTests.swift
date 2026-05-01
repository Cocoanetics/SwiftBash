import Testing
@testable import BashSyntax

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct ErrorTests {

    @Test func unterminatedDoubleQuoteThrows() {
        let err = #expect(throws: BashSyntaxError.self) {
            try BashSyntax.parse(#"echo "unterminated"#)
        }
        guard case .parsing(let msg, _, _) = err else {
            Issue.record("expected parsing error, got \(String(describing: err))")
            return
        }
        #expect(msg.contains("unexpected EOF"), "\(msg)")
    }

    @Test func unterminatedCommandSubstitutionThrows() {
        let err = #expect(throws: BashSyntaxError.self) {
            try BashSyntax.parse("echo $(true")
        }
        guard case .parsing(let msg, _, _) = err else {
            Issue.record("expected parsing error, got \(String(describing: err))")
            return
        }
        #expect(msg.contains("unexpected EOF"), "\(msg)")
    }

    @Test func unbalancedBraceThrows() {
        #expect(throws: BashSyntaxError.self) {
            try BashSyntax.parse("{ echo;")
        }
    }

    @Test func errorCarriesPosition() {
        let err = #expect(throws: BashSyntaxError.self) {
            try BashSyntax.parse("if true; then")
        }
        guard let err else {
            Issue.record("expected BashSyntaxError")
            return
        }
        #expect(err.position != nil)
        #expect(err.source != nil)
        #expect(err.source == "if true; then")
    }
}
#endif
