import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct BcCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    private func bc(_ input: String, flags: String = "") async throws -> String {
        let cap = makeShell()
        try await cap.shell.run("printf %s '\(input.replacingOccurrences(of: "'", with: "'\\''"))' | bc \(flags)")
        return cap.stdout
    }

    @Test func arithmetic() async throws {
        let out = try await bc("3 + 4\n")
        #expect(out == "7\n")
    }

    @Test func precedence() async throws {
        let out = try await bc("2 + 3 * 4\n")
        #expect(out == "14\n")
    }

    @Test func parentheses() async throws {
        let out = try await bc("(2 + 3) * 4\n")
        #expect(out == "20\n")
    }

    @Test func powerOperator() async throws {
        let out = try await bc("2 ^ 10\n")
        #expect(out == "1024\n")
    }

    @Test func divisionTruncatesAtScale0() async throws {
        let out = try await bc("7 / 2\n")
        #expect(out == "3\n")
    }

    @Test func scaleAffectsDivision() async throws {
        let out = try await bc("scale = 4\n7 / 2\n")
        #expect(out == "3.5\n")
    }

    @Test func variables() async throws {
        let out = try await bc("x = 10\nx + 5\n")
        #expect(out == "15\n")
    }

    @Test func sqrtBuiltin() async throws {
        let out = try await bc("sqrt(16)\n")
        #expect(out == "4\n")
    }

    @Test func comparisonReturns01() async throws {
        let out = try await bc("5 > 3\n5 == 3\n")
        #expect(out == "1\n0\n")
    }

    @Test func logicalOps() async throws {
        let out = try await bc("1 && 0\n0 || 1\n")
        #expect(out == "0\n1\n")
    }

    @Test func divideByZeroReports() async throws {
        let cap = makeShell()
        try await cap.shell.run("printf '5 / 0\\n' | bc")
        #expect(cap.stderr.contains("divide by zero"))
    }

    @Test func mathlibSets() async throws {
        let out = try await bc("4 / 3\n", flags: "-l")
        // With -l, scale=20, so 4/3 has decimals.
        #expect(out.contains("1.333"))
    }

    @Test func commentsStripped() async throws {
        let out = try await bc("# this is a comment\n5 + 5  /* inline */ + 1\n")
        #expect(out == "11\n")
    }

    @Test func quitExits() async throws {
        let out = try await bc("3 + 4\nquit\n9 + 9\n")
        // Last line never executes.
        #expect(out == "7\n")
    }

    // MARK: ; statement separator

    @Test func semicolonSeparatedStatementsOnOneLine() async throws {
        // The canonical bc one-liner: assign scale, then evaluate.
        let out = try await bc("scale=4; 22/7\n")
        #expect(out == "3.1428\n")
    }

    @Test func semicolonChainPrintsEachExprResult() async throws {
        let out = try await bc("2+2; 3*3; 4^2\n")
        #expect(out == "4\n9\n16\n")
    }

    @Test func semicolonAssignmentsThenExpression() async throws {
        let out = try await bc("x=10; y=20; x+y\n")
        #expect(out == "30\n")
    }

    @Test func semicolonHaltStops() async throws {
        // halt before further statements → none of them execute.
        let out = try await bc("3+3; halt; 99\n")
        #expect(out == "6\n")
    }
}
#endif
