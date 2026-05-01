import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct CutAdvancedTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func fieldsBasic() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a:b:c\\n' | cut -d: -f2")
        #expect(cap.stdout == "b\n")
    }

    @Test func fieldsRange() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a:b:c:d:e\\n' | cut -d: -f2-4")
        #expect(cap.stdout == "b:c:d\n")
    }

    @Test func charactersMode() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'abcdef\\n' | cut -c2-4")
        #expect(cap.stdout == "bcd\n")
    }

    @Test func bytesMode() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'abcdef\\n' | cut -b1,3,5")
        #expect(cap.stdout == "ace\n")
    }

    @Test func complement() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a:b:c:d\\n' | cut -d: -f2 --complement")
        #expect(cap.stdout == "a:c:d\n")
    }

    @Test func outputDelimiter() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"printf 'a:b:c\n' | cut -d: -f1,3 --output-delimiter=,"#)
        #expect(cap.stdout == "a,c\n")
    }

    @Test func onlyDelimited() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'no-delim\\nx:y\\n' | cut -d: -f1 -s")
        #expect(cap.stdout == "x\n")
    }

    @Test func openEndedRange() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a:b:c:d\\n' | cut -d: -f2-")
        #expect(cap.stdout == "b:c:d\n")
    }
}
