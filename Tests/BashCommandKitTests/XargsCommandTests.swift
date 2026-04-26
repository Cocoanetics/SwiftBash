import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct XargsCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func defaultEcho() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\nb\\nc\\n' | xargs")
        #expect(cap.stdout == "a b c\n")
    }

    @Test func withCommand() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\nb\\nc\\n' | xargs echo prefix")
        #expect(cap.stdout == "prefix a b c\n")
    }

    @Test func dashN() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a b c d\\n' | xargs -n 2 echo")
        // Should run echo twice: "a b" then "c d"
        #expect(cap.stdout == "a b\nc d\n")
    }

    @Test func dashI() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\nb\\n' | xargs -I X echo got X done")
        #expect(cap.stdout == "got a done\ngot b done\n")
    }

    @Test func dashZero() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\0b\\0c\\0' | xargs -0 echo")
        #expect(cap.stdout == "a b c\n")
    }

    @Test func customDelimiter() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a:b:c\\n' | xargs -d : echo")
        #expect(cap.stdout == "a b c\n")
    }

    @Test func emptyInputDashR() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf '' | xargs -r echo SHOULD_NOT_RUN")
        #expect(cap.stdout == "")
    }

    @Test func verbose() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\n' | xargs -t echo X")
        #expect(cap.stderr.contains("echo"))
        #expect(cap.stdout == "X a\n")
    }
}
