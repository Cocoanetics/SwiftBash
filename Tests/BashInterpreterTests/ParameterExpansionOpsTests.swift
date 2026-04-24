import XCTest
@testable import BashInterpreter

/// Tests for the `${…}` parameter-expansion operators — drives the
/// feature through `Shell.run` so both the parser, expansion, and
/// builtin-invocation paths are exercised together.
final class ParameterExpansionOpsTests: XCTestCase {

    // MARK: Plain and length

    func testPlainBraced() throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try cap.shell.run(#"echo "${NAME}""#)
        XCTAssertEqual(cap.stdout, "oliver\n")
    }

    func testLength() throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try cap.shell.run("echo ${#NAME}")
        XCTAssertEqual(cap.stdout, "6\n")
    }

    func testLengthOfUnset() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo ${#NOPE}")
        XCTAssertEqual(cap.stdout, "0\n")
    }

    // MARK: Default value `:-` and `-`

    func testDefaultValueWhenUnset() throws {
        let cap = CapturingShell()
        try cap.shell.run(#"echo "${X:-fallback}""#)
        XCTAssertEqual(cap.stdout, "fallback\n")
    }

    func testDefaultValueWhenSet() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "value"
        try cap.shell.run(#"echo "${X:-fallback}""#)
        XCTAssertEqual(cap.stdout, "value\n")
    }

    func testDefaultValueColonEmptyTriggers() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = ""
        try cap.shell.run(#"echo "${X:-fallback}""#)
        XCTAssertEqual(cap.stdout, "fallback\n", "`:-` treats empty as missing")
    }

    func testDefaultValueWithoutColonEmptyDoesNotTrigger() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = ""
        try cap.shell.run(#"echo "${X-fallback}""#)
        XCTAssertEqual(cap.stdout, "\n", "`-` only triggers when truly unset")
    }

    func testDefaultValueIsRecursivelyExpanded() throws {
        let cap = CapturingShell()
        cap.shell.environment["OTHER"] = "from-other"
        try cap.shell.run(#"echo "${UNSET:-$OTHER}""#)
        XCTAssertEqual(cap.stdout, "from-other\n")
    }

    func testDefaultValueDoesNotSetVariable() throws {
        let cap = CapturingShell()
        try cap.shell.run("echo ${X:-default}")
        XCTAssertNil(cap.shell.environment["X"])
    }

    // MARK: Assign-default `:=` and `=`

    func testAssignDefaultSetsVariable() throws {
        let cap = CapturingShell()
        try cap.shell.run(#"echo "${X:=new}""#)
        XCTAssertEqual(cap.stdout, "new\n")
        XCTAssertEqual(cap.shell.environment["X"], "new")
    }

    func testAssignDefaultDoesNotOverrideSet() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "already"
        try cap.shell.run(#"echo "${X:=new}""#)
        XCTAssertEqual(cap.stdout, "already\n")
        XCTAssertEqual(cap.shell.environment["X"], "already")
    }

    // MARK: Error-if-unset `:?` and `?`

    func testErrorIfUnsetThrows() {
        let cap = CapturingShell()
        XCTAssertThrowsError(try cap.shell.run(#"echo "${MISSING:?required}""#)) { err in
            guard let e = err as? BashInterpreterError else {
                return XCTFail("got \(err)")
            }
            XCTAssertTrue(e.description.contains("required"), e.description)
        }
    }

    func testErrorIfSetPassesThrough() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "yes"
        try cap.shell.run(#"echo "${X:?required}""#)
        XCTAssertEqual(cap.stdout, "yes\n")
    }

    // MARK: Alternative `:+` and `+`

    func testAlternativeWhenSet() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = "present"
        try cap.shell.run(#"echo "${X:+alt}""#)
        XCTAssertEqual(cap.stdout, "alt\n")
    }

    func testAlternativeWhenUnset() throws {
        let cap = CapturingShell()
        try cap.shell.run(#"echo "${X:+alt}""#)
        XCTAssertEqual(cap.stdout, "\n")
    }

    func testAlternativeColonEmptyDoesNotTrigger() throws {
        let cap = CapturingShell()
        cap.shell.environment["X"] = ""
        try cap.shell.run(#"echo "${X:+alt}""#)
        XCTAssertEqual(cap.stdout, "\n")
    }

    // MARK: Prefix removal

    func testRemoveShortestPrefix() throws {
        let cap = CapturingShell()
        cap.shell.environment["PATH"] = "/usr/local/bin"
        try cap.shell.run(#"echo "${PATH#*/}""#)
        XCTAssertEqual(cap.stdout, "usr/local/bin\n")
    }

    func testRemoveLongestPrefix() throws {
        let cap = CapturingShell()
        cap.shell.environment["PATH"] = "/usr/local/bin"
        try cap.shell.run(#"echo "${PATH##*/}""#)
        XCTAssertEqual(cap.stdout, "bin\n")
    }

    func testPrefixWithLiteral() throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "src/main.swift"
        try cap.shell.run(#"echo "${FILE#src/}""#)
        XCTAssertEqual(cap.stdout, "main.swift\n")
    }

    func testPrefixNoMatchReturnsUnchanged() throws {
        let cap = CapturingShell()
        cap.shell.environment["NAME"] = "oliver"
        try cap.shell.run(#"echo "${NAME#z*}""#)
        XCTAssertEqual(cap.stdout, "oliver\n")
    }

    // MARK: Suffix removal

    func testRemoveShortestSuffix() throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "archive.tar.gz"
        try cap.shell.run(#"echo "${FILE%.*}""#)
        XCTAssertEqual(cap.stdout, "archive.tar\n")
    }

    func testRemoveLongestSuffix() throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "archive.tar.gz"
        try cap.shell.run(#"echo "${FILE%%.*}""#)
        XCTAssertEqual(cap.stdout, "archive\n")
    }

    // MARK: Replace

    func testReplaceFirst() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try cap.shell.run(#"echo "${S/foo/X}""#)
        XCTAssertEqual(cap.stdout, "X bar foo\n")
    }

    func testReplaceAll() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try cap.shell.run(#"echo "${S//foo/X}""#)
        XCTAssertEqual(cap.stdout, "X bar X\n")
    }

    func testReplaceAtStart() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try cap.shell.run(#"echo "${S/#foo/X}""#)
        XCTAssertEqual(cap.stdout, "X bar foo\n")
    }

    func testReplaceAtStartNoMatch() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "bar foo"
        try cap.shell.run(#"echo "${S/#foo/X}""#)
        XCTAssertEqual(cap.stdout, "bar foo\n")
    }

    func testReplaceAtEnd() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "foo bar foo"
        try cap.shell.run(#"echo "${S/%foo/X}""#)
        XCTAssertEqual(cap.stdout, "foo bar X\n")
    }

    func testReplaceEmptyReplacement() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "hello-world"
        try cap.shell.run(#"echo "${S/-/}""#)
        XCTAssertEqual(cap.stdout, "helloworld\n")
    }

    func testReplaceWithGlob() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "aXXXb"
        try cap.shell.run(#"echo "${S/X*X/Y}""#)
        XCTAssertEqual(cap.stdout, "aYb\n")
    }

    // MARK: Substring

    func testSubstringOffsetOnly() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abcdef"
        try cap.shell.run(#"echo "${S:2}""#)
        XCTAssertEqual(cap.stdout, "cdef\n")
    }

    func testSubstringOffsetAndLength() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abcdef"
        try cap.shell.run(#"echo "${S:2:2}""#)
        XCTAssertEqual(cap.stdout, "cd\n")
    }

    func testSubstringNegativeOffset() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abcdef"
        // Note: bash requires a space before `-` to disambiguate from
        // the default-value operator — `${S: -3}` rather than `${S:-3}`.
        try cap.shell.run(#"echo "${S: -3}""#)
        XCTAssertEqual(cap.stdout, "def\n")
    }

    func testSubstringOffsetBeyondEnd() throws {
        let cap = CapturingShell()
        cap.shell.environment["S"] = "abc"
        try cap.shell.run(#"echo "${S:10}""#)
        XCTAssertEqual(cap.stdout, "\n")
    }

    // MARK: Combinations

    func testNestedExpansionInDefault() throws {
        let cap = CapturingShell()
        cap.shell.environment["HOME"] = "/Users/oliver"
        try cap.shell.run(#"echo "${CONFIG_DIR:-${HOME}/.config}""#)
        XCTAssertEqual(cap.stdout, "/Users/oliver/.config\n")
    }

    func testPrefixRemovalThenLength() throws {
        let cap = CapturingShell()
        cap.shell.environment["FILE"] = "/tmp/note.txt"
        try cap.shell.run(#"echo "${FILE##*/}""#)
        XCTAssertEqual(cap.stdout, "note.txt\n")
        // Combining requires staged commands, which we can drive:
        try cap.shell.run(#"NAME="${FILE##*/}""#)
        XCTAssertEqual(cap.shell.environment["NAME"], "note.txt")
    }
}
