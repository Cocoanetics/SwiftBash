import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct ExpandFoldTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // expand

    @Test func expandDefault() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\tb\\n' | expand")
        // Tab at column 1 → 7 spaces to reach column 8.
        #expect(cap.stdout == "a       b\n")
    }

    @Test func expandWidth4() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\tb\\n' | expand -t 4")
        #expect(cap.stdout == "a   b\n")
    }

    @Test func expandInitial() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\tb\\tc\\n' | expand -i -t 4")
        // Only the leading tab gets expanded — there isn't one here,
        // so output is unchanged.
        #expect(cap.stdout == "a\tb\tc\n")
    }

    // unexpand

    @Test func unexpandLeadingSpaces() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf '        hi\\n' | unexpand")
        #expect(cap.stdout == "\thi\n")
    }

    @Test func unexpandAllSpaces() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a       b\\n' | unexpand -a -t 8")
        // 'a' at col 0; 7 spaces fills to col 7, then 'b'... actually
        // col 0 → 'a' at col 0, next stop is 8, need 7 chars. So 7
        // spaces become a tab.
        #expect(cap.stdout == "a\tb\n")
    }

    // fold

    @Test func foldDefault() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'abcdefghij\\n' | fold -w 3")
        #expect(cap.stdout == "abc\ndef\nghi\nj\n")
    }

    @Test func foldAtSpaces() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'one two three four\\n' | fold -w 8 -s")
        #expect(cap.stdout == "one two \nthree \nfour\n")
    }

    @Test func foldShortWidth() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'abcdef\\n' | fold -2")
        #expect(cap.stdout == "ab\ncd\nef\n")
    }
}
