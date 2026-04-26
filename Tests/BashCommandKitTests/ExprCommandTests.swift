import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct ExprCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    @Test func arithmetic() async throws {
        let cap = makeShell()
        try await cap.shell.run("expr 3 + 4")
        #expect(cap.stdout == "7\n")
    }

    @Test func precedence() async throws {
        let cap = makeShell()
        try await cap.shell.run("expr 2 + 3 \\* 4")
        #expect(cap.stdout == "14\n")
    }

    @Test func parentheses() async throws {
        let cap = makeShell()
        try await cap.shell.run("expr \\( 2 + 3 \\) \\* 4")
        #expect(cap.stdout == "20\n")
    }

    @Test func divisionTruncates() async throws {
        let cap = makeShell()
        try await cap.shell.run("expr 7 / 2")
        #expect(cap.stdout == "3\n")
    }

    @Test func modulo() async throws {
        let cap = makeShell()
        try await cap.shell.run("expr 17 % 5")
        #expect(cap.stdout == "2\n")
    }

    @Test func comparisonNumeric() async throws {
        let cap = makeShell()
        try await cap.shell.run("expr 5 \\> 3")
        #expect(cap.stdout == "1\n")
    }

    @Test func comparisonFalseExitsOne() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("expr 1 = 2")
        #expect(cap.stdout == "0\n")
        #expect(status == ExitStatus(1))
    }

    @Test func length() async throws {
        let cap = makeShell()
        try await cap.shell.run("expr length hello")
        #expect(cap.stdout == "5\n")
    }

    @Test func substr() async throws {
        let cap = makeShell()
        try await cap.shell.run("expr substr abcdef 2 3")
        #expect(cap.stdout == "bcd\n")
    }

    @Test func indexBuiltin() async throws {
        let cap = makeShell()
        try await cap.shell.run("expr index hello l")
        #expect(cap.stdout == "3\n")
    }

    @Test func matchOperatorAnchored() async throws {
        let cap = makeShell()
        // Match anchored at start; no capture group → length of match.
        try await cap.shell.run("expr foobar : foo")
        #expect(cap.stdout == "3\n")
    }

    @Test func matchCaptureGroup() async throws {
        let cap = makeShell()
        // Capture group → contents of group.
        try await cap.shell.run("expr abc123 : '[a-z]*\\([0-9]*\\)'")
        #expect(cap.stdout == "123\n")
    }

    @Test func divisionByZeroFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("expr 5 / 0")
        #expect(status == ExitStatus(2))
        #expect(cap.stderr.contains("expr"))
    }

    @Test func nonIntegerArgError() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("expr abc + 1")
        #expect(status == ExitStatus(2))
    }
}
