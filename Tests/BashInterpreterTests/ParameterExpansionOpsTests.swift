import XCTest
@testable import BashInterpreter

/// Tests for the `${…}` parameter-expansion operators — drives the
/// feature through `Shell.run` so both the parser, expansion, and
/// builtin-invocation paths are exercised together.
final class ParameterExpansionOpsTests: XCTestCase {

    // MARK: Plain and length

    func testPlainBraced() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run(#"echo "${NAME}""#)
        XCTAssertEqual(cap.stdout, "oliver\n")
    }

    func testLength() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run("echo ${#NAME}")
        XCTAssertEqual(cap.stdout, "6\n")
    }

    func testLengthOfUnset() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo ${#NOPE}")
        XCTAssertEqual(cap.stdout, "0\n")
    }

    // MARK: Default value `:-` and `-`

    func testDefaultValueWhenUnset() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:-fallback}""#)
        XCTAssertEqual(cap.stdout, "fallback\n")
    }

    func testDefaultValueWhenSet() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "value"
        try await cap.shell.run(#"echo "${X:-fallback}""#)
        XCTAssertEqual(cap.stdout, "value\n")
    }

    func testDefaultValueColonEmptyTriggers() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = ""
        try await cap.shell.run(#"echo "${X:-fallback}""#)
        XCTAssertEqual(cap.stdout, "fallback\n", "`:-` treats empty as missing")
    }

    func testDefaultValueWithoutColonEmptyDoesNotTrigger() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = ""
        try await cap.shell.run(#"echo "${X-fallback}""#)
        XCTAssertEqual(cap.stdout, "\n", "`-` only triggers when truly unset")
    }

    func testDefaultValueIsRecursivelyExpanded() async throws {
        let cap = CapturingShell()
        cap.shell.environment["OTHER"] = "from-other"
        try await cap.shell.run(#"echo "${UNSET:-$OTHER}""#)
        XCTAssertEqual(cap.stdout, "from-other\n")
    }

    func testDefaultValueDoesNotSetVariable() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo ${X:-default}")
        XCTAssertNil(cap.shell.environment["X"])
    }

    // MARK: Assign-default `:=` and `=`

    func testAssignDefaultSetsVariable() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:=new}""#)
        XCTAssertEqual(cap.stdout, "new\n")
        XCTAssertEqual(cap.shell.environment["X"], "new")
    }

    func testAssignDefaultDoesNotOverrideSet() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "already"
        try await cap.shell.run(#"echo "${X:=new}""#)
        XCTAssertEqual(cap.stdout, "already\n")
        XCTAssertEqual(cap.shell.environment["X"], "already")
    }

    // MARK: Error-if-unset `:?` and `?`

    func testErrorIfUnsetThrows() async {
        let cap = CapturingShell()
        await XCTAssertThrowsErrorAsync(try await cap.shell.run(#"echo "${MISSING:?required}""#)) { err in
            guard let e = err as? BashInterpreterError else {
                return XCTFail("got \(err)")
            }
            XCTAssertTrue(e.description.contains("required"), e.description)
        }
    }

    func testErrorIfSetPassesThrough() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "yes"
        try await cap.shell.run(#"echo "${X:?required}""#)
        XCTAssertEqual(cap.stdout, "yes\n")
    }

    // MARK: Alternative `:+` and `+`

    func testAlternativeWhenSet() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "present"
        try await cap.shell.run(#"echo "${X:+alt}""#)
        XCTAssertEqual(cap.stdout, "alt\n")
    }

    func testAlternativeWhenUnset() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "${X:+alt}""#)
        XCTAssertEqual(cap.stdout, "\n")
    }

    func testAlternativeColonEmptyDoesNotTrigger() async throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = ""
        try await cap.shell.run(#"echo "${X:+alt}""#)
        XCTAssertEqual(cap.stdout, "\n")
    }

    // MARK: Prefix removal

    func testRemoveShortestPrefix() async throws {
        let cap = CapturingShell()
        cap.shell.environment["PATH"] = "/usr/local/bin"
        try await cap.shell.run(#"echo "${PATH#*/}""#)
        XCTAssertEqual(cap.stdout, "usr/local/bin\n")
    }

    func testRemoveLongestPrefix() async throws {
        let cap = CapturingShell()
        cap.shell.environment["PATH"] = "/usr/local/bin"
        try await cap.shell.run(#"echo "${PATH##*/}""#)
        XCTAssertEqual(cap.stdout, "bin\n")
    }

    func testPrefixWithLiteral() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "src/main.swift"
        try await cap.shell.run(#"echo "${FILE#src/}""#)
        XCTAssertEqual(cap.stdout, "main.swift\n")
    }

    func testPrefixNoMatchReturnsUnchanged() async throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try await cap.shell.run(#"echo "${NAME#z*}""#)
        XCTAssertEqual(cap.stdout, "oliver\n")
    }

    // MARK: Suffix removal

    func testRemoveShortestSuffix() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "archive.tar.gz"
        try await cap.shell.run(#"echo "${FILE%.*}""#)
        XCTAssertEqual(cap.stdout, "archive.tar\n")
    }

    func testRemoveLongestSuffix() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "archive.tar.gz"
        try await cap.shell.run(#"echo "${FILE%%.*}""#)
        XCTAssertEqual(cap.stdout, "archive\n")
    }

    // MARK: Replace

    func testReplaceFirst() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try await cap.shell.run(#"echo "${S/foo/X}""#)
        XCTAssertEqual(cap.stdout, "X bar foo\n")
    }

    func testReplaceAll() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try await cap.shell.run(#"echo "${S//foo/X}""#)
        XCTAssertEqual(cap.stdout, "X bar X\n")
    }

    func testReplaceAtStart() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try await cap.shell.run(#"echo "${S/#foo/X}""#)
        XCTAssertEqual(cap.stdout, "X bar foo\n")
    }

    func testReplaceAtStartNoMatch() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "bar foo"
        try await cap.shell.run(#"echo "${S/#foo/X}""#)
        XCTAssertEqual(cap.stdout, "bar foo\n")
    }

    func testReplaceAtEnd() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try await cap.shell.run(#"echo "${S/%foo/X}""#)
        XCTAssertEqual(cap.stdout, "foo bar X\n")
    }

    func testReplaceEmptyReplacement() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "hello-world"
        try await cap.shell.run(#"echo "${S/-/}""#)
        XCTAssertEqual(cap.stdout, "helloworld\n")
    }

    func testReplaceWithGlob() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "aXXXb"
        try await cap.shell.run(#"echo "${S/X*X/Y}""#)
        XCTAssertEqual(cap.stdout, "aYb\n")
    }

    // MARK: Substring

    func testSubstringOffsetOnly() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abcdef"
        try await cap.shell.run(#"echo "${S:2}""#)
        XCTAssertEqual(cap.stdout, "cdef\n")
    }

    func testSubstringOffsetAndLength() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abcdef"
        try await cap.shell.run(#"echo "${S:2:2}""#)
        XCTAssertEqual(cap.stdout, "cd\n")
    }

    func testSubstringNegativeOffset() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abcdef"
        // Note: bash requires a space before `-` to disambiguate from
        // the default-value operator — `${S: -3}` rather than `${S:-3}`.
        try await cap.shell.run(#"echo "${S: -3}""#)
        XCTAssertEqual(cap.stdout, "def\n")
    }

    func testSubstringOffsetBeyondEnd() async throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abc"
        try await cap.shell.run(#"echo "${S:10}""#)
        XCTAssertEqual(cap.stdout, "\n")
    }

    // MARK: Combinations

    func testNestedExpansionInDefault() async throws {
        let cap = CapturingShell()
        cap.shell.environment["HOME"] = "/Users/oliver"
        try await cap.shell.run(#"echo "${CONFIG_DIR:-${HOME}/.config}""#)
        XCTAssertEqual(cap.stdout, "/Users/oliver/.config\n")
    }

    func testPrefixRemovalThenLength() async throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "/tmp/note.txt"
        try await cap.shell.run(#"echo "${FILE##*/}""#)
        XCTAssertEqual(cap.stdout, "note.txt\n")
        // Combining requires staged commands, which we can drive:
        try await cap.shell.run(#"NAME="${FILE##*/}""#)
        XCTAssertEqual(cap.shell.environment["NAME"], "note.txt")
    }
}
