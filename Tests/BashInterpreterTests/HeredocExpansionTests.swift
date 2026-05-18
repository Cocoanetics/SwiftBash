import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct HeredocExpansionTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.installShellBuiltin(name: "capture") { _ in
            let input = await Shell.bashCurrent.stdin.readAllString()
            Shell.bashCurrent.stdout(input)
            return .success
        }
        return cap
    }

    // MARK: Unquoted delimiter — body expands

    @Test func plainVariableExpands() async throws {
        let cap = makeShell()
        cap.shell.environment["NAME"] = "world"
        try await cap.shell.run("""
            capture <<EOF
            hello $NAME
            EOF
            """)
        #expect(cap.stdout == "hello world\n")
    }

    @Test func bracedVariableExpands() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "value"
        try await cap.shell.run("""
            capture <<EOF
            <${X}>
            EOF
            """)
        #expect(cap.stdout == "<value>\n")
    }

    @Test func parameterFormExpands() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            <${MISSING:-fallback}>
            EOF
            """)
        #expect(cap.stdout == "<fallback>\n")
    }

    @Test func arithmeticExpands() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            sum=$((1 + 2 * 3))
            EOF
            """)
        #expect(cap.stdout == "sum=7\n")
    }

    @Test func commandSubstitutionExpands() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            today=$(echo computed)
            EOF
            """)
        #expect(cap.stdout == "today=computed\n")
    }

    @Test func backtickSubstitutionExpands() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            echoed=`echo backed`
            EOF
            """)
        #expect(cap.stdout == "echoed=backed\n")
    }

    @Test func multipleSubstitutions() async throws {
        let cap = makeShell()
        cap.shell.environment["GREETING"] = "hi"
        cap.shell.environment["NAME"] = "alex"
        try await cap.shell.run("""
            capture <<EOF
            $GREETING, $NAME — total=$((40 + 2))
            EOF
            """)
        #expect(cap.stdout == "hi, alex — total=42\n")
    }

    @Test func positionalParameters() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["first", "second"]
        try await cap.shell.run("""
            capture <<EOF
            args: $1 and $2 ($# total)
            EOF
            """)
        #expect(cap.stdout == "args: first and second (2 total)\n")
    }

    // MARK: Backslash escapes

    @Test func backslashEscapesDollar() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "expanded"
        try await cap.shell.run("""
            capture <<EOF
            literal \\$X but real $X
            EOF
            """)
        #expect(cap.stdout == "literal $X but real expanded\n")
    }

    @Test func backslashEscapesBacktick() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            \\`literal\\`
            EOF
            """)
        #expect(cap.stdout == "`literal`\n")
    }

    @Test func backslashEscapesBackslash() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            one\\\\two
            EOF
            """)
        #expect(cap.stdout == "one\\two\n")
    }

    @Test func backslashOnOtherCharIsLiteral() async throws {
        // Backslash before a non-special char is preserved (matches bash).
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            keep \\n literal
            EOF
            """)
        #expect(cap.stdout == "keep \\n literal\n")
    }

    // MARK: Quoted delimiter — body is verbatim

    @Test func singleQuotedDelimiterDisablesExpansion() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "should-not-show"
        try await cap.shell.run("""
            capture <<'EOF'
            $X $(echo nope)
            EOF
            """)
        #expect(cap.stdout == "$X $(echo nope)\n")
    }

    @Test func doubleQuotedDelimiterDisablesExpansion() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "should-not-show"
        try await cap.shell.run("""
            capture <<"EOF"
            $X stays literal
            EOF
            """)
        #expect(cap.stdout == "$X stays literal\n")
    }

    @Test func backslashedDelimiterDisablesExpansion() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "should-not-show"
        try await cap.shell.run("""
            capture <<\\EOF
            $X stays literal
            EOF
            """)
        #expect(cap.stdout == "$X stays literal\n")
    }

    // MARK: No globbing or word splitting in body

    @Test func bodyDoesNotGlob() async throws {
        let cap = makeShell()
        cap.shell.environment["P"] = "*.swift"
        try await cap.shell.run("""
            capture <<EOF
            pattern=$P
            EOF
            """)
        // The expansion of $P inside the body should NOT trigger
        // pathname expansion; body text is treated like inside-double-
        // quotes context.
        #expect(cap.stdout == "pattern=*.swift\n")
    }

    @Test func bodyDoesNotWordSplit() async throws {
        // Even with IFS=":", the heredoc body's substitutions don't
        // get field-split — heredoc bodies are double-quote semantics.
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        cap.shell.environment["X"] = "a:b:c"
        try await cap.shell.run("""
            capture <<EOF
            value=$X
            EOF
            """)
        #expect(cap.stdout == "value=a:b:c\n")
    }

    // MARK: Pipelines + redirections together

    @Test func heredocFedIntoCommandViaRedirect() async throws {
        let cap = makeShell()
        cap.shell.installShellBuiltin(name: "wc-l") { _ in
            var count = 0
            for await _ in Shell.bashCurrent.stdin.lines { count += 1 }
            Shell.bashCurrent.stdout("\(count)\n")
            return .success
        }
        cap.shell.environment["NAME"] = "world"
        try await cap.shell.run("""
            wc-l <<EOF
            hi $NAME
            second line
            EOF
            """)
        #expect(cap.stdout == "2\n")
    }

    // MARK: Edge cases

    @Test func dollarAtEndOfBodyIsLiteral() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            ends with \\$
            EOF
            """)
        #expect(cap.stdout == "ends with $\n")
    }

    @Test func unsetVariableExpandsToEmpty() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            <$NOPE>
            EOF
            """)
        #expect(cap.stdout == "<>\n")
    }

    @Test func nestedCommandSubstitution() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            capture <<EOF
            value=$(echo $(echo deep))
            EOF
            """)
        #expect(cap.stdout == "value=deep\n")
    }
}
