import Testing
@testable import BashInterpreter

/// Tests for the `${…}` parameter-expansion operators — drives the
/// feature through `Shell.run` so both the parser, expansion, and
/// builtin-invocation paths are exercised together.
#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct ParameterExpansionOpsTests {

    // MARK: Plain and length

    @Test func plainBraced() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run(#"echo "${NAME}""#)
        #expect(cap.stdout == "oliver\n")
    }

    @Test func length() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run("echo ${#NAME}")
        #expect(cap.stdout == "6\n")
    }

    @Test func lengthOfUnset() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo ${#NOPE}")
        #expect(cap.stdout == "0\n")
    }

    // MARK: Default value `:-` and `-`

    @Test func defaultValueWhenUnset() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:-fallback}""#)
        #expect(cap.stdout == "fallback\n")
    }

    @Test func defaultValueWhenSet() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "value"
        try await cap.shell.run(#"echo "${X:-fallback}""#)
        #expect(cap.stdout == "value\n")
    }

    @Test func defaultValueColonEmptyTriggers() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = ""
        try await cap.shell.run(#"echo "${X:-fallback}""#)
        #expect(cap.stdout == "fallback\n", "`:-` treats empty as missing")
    }

    @Test func defaultValueWithoutColonEmptyDoesNotTrigger() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = ""
        try await cap.shell.run(#"echo "${X-fallback}""#)
        #expect(cap.stdout == "\n", "`-` only triggers when truly unset")
    }

    @Test func defaultValueIsRecursivelyExpanded() async throws {
        let cap = CapturingShell()
        cap.shell.environment["OTHER"] = "from-other"
        try await cap.shell.run(#"echo "${UNSET:-$OTHER}""#)
        #expect(cap.stdout == "from-other\n")
    }

    @Test func defaultValueDoesNotSetVariable() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo ${X:-default}")
        #expect(cap.shell.environment["X"] == nil)
    }

    // MARK: Assign-default `:=` and `=`

    @Test func assignDefaultSetsVariable() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:=new}""#)
        #expect(cap.stdout == "new\n")
        #expect(cap.shell.environment["X"] == "new")
    }

    @Test func assignDefaultDoesNotOverrideSet() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "already"
        try await cap.shell.run(#"echo "${X:=new}""#)
        #expect(cap.stdout == "already\n")
        #expect(cap.shell.environment["X"] == "already")
    }

    // MARK: Error-if-unset `:?` and `?`

    @Test func errorIfUnsetWritesToStderrAndExits() async throws {
        // Bash semantics: emit `script:line: var: msg` to stderr and
        // exit the shell with status 1 (status surfacing as `$?` in
        // a subshell). The throw is captured by the top-level run
        // and does not propagate out of `cap.shell.run`.
        let cap = CapturingShell()
        let status = try await cap.shell.run(#"echo "${MISSING:?required}""#)
        #expect(status.code == 1)
        #expect(cap.stderr.contains("MISSING: required"))
    }

    @Test func errorIfSetPassesThrough() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "yes"
        try await cap.shell.run(#"echo "${X:?required}""#)
        #expect(cap.stdout == "yes\n")
    }

    // MARK: Alternative `:+` and `+`

    @Test func alternativeWhenSet() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "present"
        try await cap.shell.run(#"echo "${X:+alt}""#)
        #expect(cap.stdout == "alt\n")
    }

    @Test func alternativeWhenUnset() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:+alt}""#)
        #expect(cap.stdout == "\n")
    }

    @Test func alternativeColonEmptyDoesNotTrigger() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = ""
        try await cap.shell.run(#"echo "${X:+alt}""#)
        #expect(cap.stdout == "\n")
    }

    // MARK: Prefix removal

    @Test func removeShortestPrefix() async throws {
        let cap = CapturingShell()
        cap.shell.environment["PATH"] = "/usr/local/bin"
        try await cap.shell.run(#"echo "${PATH#*/}""#)
        #expect(cap.stdout == "usr/local/bin\n")
    }

    @Test func removeLongestPrefix() async throws {
        let cap = CapturingShell()
        cap.shell.environment["PATH"] = "/usr/local/bin"
        try await cap.shell.run(#"echo "${PATH##*/}""#)
        #expect(cap.stdout == "bin\n")
    }

    @Test func prefixWithLiteral() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "src/main.swift"
        try await cap.shell.run(#"echo "${FILE#src/}""#)
        #expect(cap.stdout == "main.swift\n")
    }

    @Test func prefixNoMatchReturnsUnchanged() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run(#"echo "${NAME#z*}""#)
        #expect(cap.stdout == "oliver\n")
    }

    // MARK: Suffix removal

    @Test func removeShortestSuffix() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "archive.tar.gz"
        try await cap.shell.run(#"echo "${FILE%.*}""#)
        #expect(cap.stdout == "archive.tar\n")
    }

    @Test func removeLongestSuffix() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "archive.tar.gz"
        try await cap.shell.run(#"echo "${FILE%%.*}""#)
        #expect(cap.stdout == "archive\n")
    }

    // MARK: Replace

    @Test func replaceFirst() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try await cap.shell.run(#"echo "${S/foo/X}""#)
        #expect(cap.stdout == "X bar foo\n")
    }

    @Test func replaceAll() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try await cap.shell.run(#"echo "${S//foo/X}""#)
        #expect(cap.stdout == "X bar X\n")
    }

    @Test func replaceAtStart() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try await cap.shell.run(#"echo "${S/#foo/X}""#)
        #expect(cap.stdout == "X bar foo\n")
    }

    @Test func replaceAtStartNoMatch() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "bar foo"
        try await cap.shell.run(#"echo "${S/#foo/X}""#)
        #expect(cap.stdout == "bar foo\n")
    }

    @Test func replaceAtEnd() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try await cap.shell.run(#"echo "${S/%foo/X}""#)
        #expect(cap.stdout == "foo bar X\n")
    }

    @Test func replaceEmptyReplacement() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "hello-world"
        try await cap.shell.run(#"echo "${S/-/}""#)
        #expect(cap.stdout == "helloworld\n")
    }

    @Test func replaceWithGlob() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "aXXXb"
        try await cap.shell.run(#"echo "${S/X*X/Y}""#)
        #expect(cap.stdout == "aYb\n")
    }

    // MARK: Substring

    @Test func substringOffsetOnly() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abcdef"
        try await cap.shell.run(#"echo "${S:2}""#)
        #expect(cap.stdout == "cdef\n")
    }

    @Test func substringOffsetAndLength() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abcdef"
        try await cap.shell.run(#"echo "${S:2:2}""#)
        #expect(cap.stdout == "cd\n")
    }

    @Test func substringNegativeOffset() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abcdef"
        // Note: bash requires a space before `-` to disambiguate from
        // the default-value operator — `${S: -3}` rather than `${S:-3}`.
        try await cap.shell.run(#"echo "${S: -3}""#)
        #expect(cap.stdout == "def\n")
    }

    @Test func substringOffsetBeyondEnd() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abc"
        try await cap.shell.run(#"echo "${S:10}""#)
        #expect(cap.stdout == "\n")
    }

    // MARK: Combinations

    @Test func nestedExpansionInDefault() async throws {
        let cap = CapturingShell()
        cap.shell.environment["HOME"] = "/Users/oliver"
        try await cap.shell.run(#"echo "${CONFIG_DIR:-${HOME}/.config}""#)
        #expect(cap.stdout == "/Users/oliver/.config\n")
    }

    @Test func prefixRemovalThenLength() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "/tmp/note.txt"
        try await cap.shell.run(#"echo "${FILE##*/}""#)
        #expect(cap.stdout == "note.txt\n")
        // Combining requires staged commands, which we can drive:
        try await cap.shell.run(#"NAME="${FILE##*/}""#)
        #expect(cap.shell.environment["NAME"] == "note.txt")
    }
}
#endif
