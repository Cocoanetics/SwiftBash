import Testing
@testable import BashInterpreter

/// Pin down the rule that the *word* inside a parameter-form operator
/// (e.g. `${var:-WORD}`, `${var:=WORD}`, `${var:?MSG}`, `${var:+WORD}`,
/// and the replacement of `${var/pat/repl}`) goes through full
/// double-quote-style expansion: `$VAR`, `${...}`, `$(...)`, `$((...))`
/// and backticks all fire.
@Suite struct ParameterFormSubstitutionTests {

    // MARK: ${var:-WORD}

    @Test func defaultViaCommandSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:-$(echo computed)}""#)
        #expect(cap.stdout == "computed\n")
    }

    @Test func defaultViaArithmetic() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:-$((1 + 2 * 3))}""#)
        #expect(cap.stdout == "7\n")
    }

    @Test func defaultViaBacktick() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:-`echo back`}""#)
        #expect(cap.stdout == "back\n")
    }

    @Test func defaultMixesLiteralAndSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:-prefix-$(echo mid)-suffix}""#)
        #expect(cap.stdout == "prefix-mid-suffix\n")
    }

    @Test func defaultIsSkippedWhenSet() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "already"
        try await cap.shell.run(#"echo "${X:-$(echo changed)}""#)
        #expect(cap.stdout == "already\n",
                "the substitution should NOT run when X is set")
    }

    // MARK: ${var:=WORD}

    @Test func assignDefaultViaCommandSub() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:=$(echo new)}""#)
        #expect(cap.stdout == "new\n")
        #expect(cap.shell.environment["X"] == "new")
    }

    @Test func assignDefaultViaArithmetic() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:=$((40 + 2))}""#)
        #expect(cap.stdout == "42\n")
        #expect(cap.shell.environment["X"] == "42")
    }

    // MARK: ${var:?MSG}

    @Test func errorMessageRunsCommandSub() async throws {
        // ${var:?MSG} runs MSG through the same expansion pipeline as
        // a regular word, so a `$(...)` substitution inside the message
        // fires before the diagnostic is written to stderr.
        let cap = CapturingShell()
        let status = try await cap.shell.run(
            #"echo "${X:?$(echo computed message)}""#)
        #expect(status.code == 1)
        #expect(cap.stderr.contains("computed message"))
    }

    // MARK: ${var:+WORD}

    @Test func alternativeViaCommandSub() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "set"
        try await cap.shell.run(#"echo "${X:+$(echo alt)}""#)
        #expect(cap.stdout == "alt\n")
    }

    @Test func alternativeNotEvaluatedIfUnset() async throws {
        let cap = CapturingShell()
        // X is unset → :+ produces empty, the substitution shouldn't run.
        try await cap.shell.run(#"echo [${X:+$(echo nope)}]"#)
        #expect(cap.stdout == "[]\n")
    }

    // MARK: ${var/pat/repl}

    @Test func replacementContainsCommandSub() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "hello world"
        try await cap.shell.run(#"echo "${S/world/$(echo planet)}""#)
        #expect(cap.stdout == "hello planet\n")
    }

    @Test func replacementContainsArithmetic() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "value=X"
        try await cap.shell.run(#"echo "${S/X/$((10 * 5))}""#)
        #expect(cap.stdout == "value=50\n")
    }

    // MARK: Nested forms

    @Test func nestedDefaultUsingDefault() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:-${Y:-$(echo deep)}}""#)
        #expect(cap.stdout == "deep\n")
    }

    @Test func nestedFormWithEnvAndCommand() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FALLBACK"] = "from-env"
        try await cap.shell.run(#"echo "${X:-${Y:-$FALLBACK}}""#)
        #expect(cap.stdout == "from-env\n")
    }

    // MARK: Side-effects don't run when not needed

    @Test func setVarPreventsCommandSubExecution() async throws {
        // The substitution shouldn't run AT ALL when X is already set.
        // We prove that by writing to a file in the substitution and
        // checking it didn't get touched.
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        try await cap.shell.fileSystem.createDirectory("/work", intermediates: true)
        cap.shell.environment.workingDirectory = "/work"
        cap.shell.environment["X"] = "preset"

        try await cap.shell.run(#"echo "${X:-$(echo bad > /work/marker)}""#)
        #expect(try await cap.shell.fileSystem.metadata("/work/marker") == nil,
                "the inner $(...) must not run when X is set")
    }
}
