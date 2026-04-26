import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct CatAdvancedTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func numberLines() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\nb\\nc\\n' | cat -n")
        #expect(cap.stdout == "     1\ta\n     2\tb\n     3\tc\n")
    }

    @Test func numberNonblank() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\n\\nb\\n' | cat -b")
        #expect(cap.stdout == "     1\ta\n\n     2\tb\n")
    }

    @Test func squeezeBlank() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\n\\n\\n\\nb\\n' | cat -s")
        #expect(cap.stdout == "a\n\nb\n")
    }

    @Test func showEnds() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'foo\\nbar\\n' | cat -E")
        #expect(cap.stdout == "foo$\nbar$\n")
    }

    @Test func showTabs() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\tb\\n' | cat -T")
        #expect(cap.stdout == "a^Ib\n")
    }

    @Test func showAll() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\tb\\n' | cat -A")
        #expect(cap.stdout == "a^Ib$\n")
    }

    @Test func combinedFlags() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf 'a\\nb\\n' | cat -nE")
        #expect(cap.stdout == "     1\ta$\n     2\tb$\n")
    }
}
