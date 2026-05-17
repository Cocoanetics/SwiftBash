import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct CompgenCommandTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: word-list action

    @Test func wordListPrefixFilter() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"compgen -W "alpha beta apple" a"#)
        #expect(cap.stdout == "alpha\napple\n")
        #expect(cap.shell.lastExitStatus.isSuccess)
    }

    @Test func wordListNoMatchExitsOne() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"compgen -W "alpha beta" zz"#)
        #expect(cap.stdout == "")
        #expect(!cap.shell.lastExitStatus.isSuccess)
    }

    @Test func wordListWithPrefixAndSuffix() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"compgen -P "[" -S "]" -W "x y" """#)
        #expect(cap.stdout == "[x]\n[y]\n")
    }

    @Test func wordListExcludePattern() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"compgen -W "foo.o bar.c baz.o" -X "*.o""#)
        #expect(cap.stdout == "bar.c\n")
    }

    // MARK: command actions

    @Test func commandsIncludesEcho() async throws {
        let cap = makeShell()
        try await cap.shell.run("compgen -c ec")
        #expect(cap.stdout.contains("echo\n"))
    }

    @Test func builtinsExcludeUserFunctions() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            myfunc() { :; }
            compgen -A function
            """)
        #expect(cap.stdout == "myfunc\n")
    }

    @Test func builtinsExcludeFunctionsInBuiltinAction() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            myfunc() { :; }
            compgen -b my
            """)
        // `myfunc` is a function, so `-b` (builtin) must skip it.
        #expect(cap.stdout == "")
    }

    // MARK: variable actions

    @Test func variablesIncludeScalar() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            FOO=1
            FOOBAR=2
            BAR=3
            compgen -v FOO
            """)
        let lines = Set(cap.stdout.split(separator: "\n").map(String.init))
        #expect(lines.contains("FOO"))
        #expect(lines.contains("FOOBAR"))
        #expect(!lines.contains("BAR"))
    }

    @Test func variablesIncludeArrays() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            declare -A myassoc
            myarr=(a b c)
            compgen -v my
            """)
        let lines = Set(cap.stdout.split(separator: "\n").map(String.init))
        #expect(lines.contains("myarr"))
        #expect(lines.contains("myassoc"))
    }

    // MARK: long-form action

    @Test func actionLongFormCommand() async throws {
        let cap = makeShell()
        try await cap.shell.run("compgen -A command ec")
        #expect(cap.stdout.contains("echo\n"))
    }

    @Test func actionInvalidName() async throws {
        let cap = makeShell()
        try await cap.shell.run("compgen -A bogus")
        #expect(!cap.shell.lastExitStatus.isSuccess)
        #expect(cap.stderr.contains("invalid action"))
    }

    // MARK: ignored modifiers

    @Test func ignoredModifiersDoNotError() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"compgen -o nospace -F _foo -W "x y" x"#)
        #expect(cap.stdout == "x\n")
        #expect(cap.shell.lastExitStatus.isSuccess)
    }

    @Test func ignoredModifierMissingArgIsUsageError() async throws {
        let cap = makeShell()
        try await cap.shell.run("compgen -F")
        // -F still requires a value; bare `compgen -F` is status 2.
        #expect(cap.shell.lastExitStatus.code == 2)
        #expect(cap.stderr.contains("option requires an argument"))
    }

    @Test func bareCompgenSucceeds() async throws {
        let cap = makeShell()
        try await cap.shell.run("compgen")
        // No generator → no-op success, not a "no matches" failure.
        #expect(cap.stdout == "")
        #expect(cap.shell.lastExitStatus.isSuccess)
    }

    @Test func wordListHonorsQuoting() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"compgen -W "alpha 'foo bar' beta""#)
        // The middle token has an internal space — should survive as
        // one candidate, not split into two.
        #expect(cap.stdout == "alpha\nfoo bar\nbeta\n")
    }

    // MARK: completion sources

    @Test func completionSourcesListCommandsAll() async throws {
        let cap = makeShell()
        let names = cap.shell.completionSources.listCommands(kind: .all)
        #expect(names.contains("echo"))
        #expect(names.contains("compgen"))
    }

    @Test func completionSourcesListFunctionsAfterDefinition() async throws {
        let cap = makeShell()
        try await cap.shell.run("greet() { :; }")
        #expect(cap.shell.completionSources.listFunctions() == ["greet"])
    }

    @Test func completionSourcesListVariablesScopes() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            FOO=1
            arr=(a b)
            declare -A assoc
            """)
        let scalar = cap.shell.completionSources.listVariables(scope: .scalar)
        let array = cap.shell.completionSources.listVariables(scope: .array)
        let assoc = cap.shell.completionSources.listVariables(scope: .associative)
        #expect(scalar.contains("FOO"))
        #expect(array.contains("arr"))
        #expect(assoc.contains("assoc"))
    }
}
