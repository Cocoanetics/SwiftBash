import Testing
import Foundation
@testable import BashInterpreter

@Suite struct ConditionalExpressionTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        cap.shell.environment.workingDirectory = "/"
        return cap
    }

    // MARK: Basics

    @Test func nullaryNonEmpty() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "yes"
        let s = try await cap.shell.run("[[ $X ]]")
        #expect(s == .success)
    }

    @Test func nullaryEmpty() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = ""
        let s = try await cap.shell.run("[[ \"$X\" ]]")
        #expect(s == .failure)
    }

    @Test func dashFFile() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(Data(), to: "/f", append: false)
        let s = try await cap.shell.run("[[ -f /f ]]")
        #expect(s == .success)
    }

    // MARK: No word splitting on substitutions (THE distinguishing feature)

    @Test func dashFSpaceyPathStaysOneOperand() async throws {
        // Plain `[ ]` would barf on the unquoted space; `[[ ]]` doesn't
        // word-split substitution results, so this works.
        let cap = makeShell()
        try await cap.shell.fileSystem.createDirectory(
            "/has space", intermediates: true)
        cap.shell.environment["F"] = "/has space"
        let s = try await cap.shell.run("[[ -d $F ]]")
        #expect(s == .success)
    }

    // MARK: Glob match with == / !=

    @Test func equalEqualGlobMatch() async throws {
        let cap = makeShell()
        cap.shell.environment["F"] = "report.txt"
        let s = try await cap.shell.run("[[ $F == *.txt ]]")
        #expect(s == .success)
    }

    @Test func equalEqualNoMatchIsFalse() async throws {
        let cap = makeShell()
        cap.shell.environment["F"] = "report.md"
        let s = try await cap.shell.run("[[ $F == *.txt ]]")
        #expect(s == .failure)
    }

    @Test func notEqualGlobMatch() async throws {
        let cap = makeShell()
        cap.shell.environment["F"] = "report.md"
        let s = try await cap.shell.run("[[ $F != *.txt ]]")
        #expect(s == .success)
    }

    @Test func quotedRhsForcesLiteral() async throws {
        // With the RHS quoted, `==` does literal compare — `*.txt`
        // matches itself, not any txt file.
        let cap = makeShell()
        cap.shell.environment["F"] = "report.txt"
        let s = try await cap.shell.run(#"[[ "$F" == "*.txt" ]]"#)
        #expect(s == .failure,
                "quoted RHS suppresses glob match — only literal '*.txt' matches")
    }

    // MARK: =~ regex

    @Test func regexMatch() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "abc123"
        let s = try await cap.shell.run(#"[[ "$X" =~ ^[a-z]+[0-9]+$ ]]"#)
        #expect(s == .success)
    }

    @Test func regexNoMatch() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "ABC123"
        let s = try await cap.shell.run(#"[[ "$X" =~ ^[a-z]+$ ]]"#)
        #expect(s == .failure)
    }

    // MARK: < and > as string compare (not redirect)

    @Test func lessThanIsStringCompare() async throws {
        let cap = makeShell()
        let s = try await cap.shell.run("[[ apple < banana ]]")
        #expect(s == .success)
    }

    @Test func greaterThanIsStringCompare() async throws {
        let cap = makeShell()
        let s = try await cap.shell.run("[[ banana > apple ]]")
        #expect(s == .success)
    }

    // MARK: integer ops

    @Test func integerComparisons() async throws {
        let cap = makeShell()
        #expect(try await cap.shell.run("[[ 5 -eq 5 ]]") == .success)
        #expect(try await cap.shell.run("[[ 5 -lt 10 ]]") == .success)
        #expect(try await cap.shell.run("[[ 10 -gt 5 ]]") == .success)
    }

    // MARK: && and || as logical (not list separators)

    @Test func logicalAnd() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "5"
        let s = try await cap.shell.run("[[ $X -gt 0 && $X -lt 10 ]]")
        #expect(s == .success)
    }

    @Test func logicalOr() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "100"
        let s = try await cap.shell.run("[[ $X -lt 0 || $X -gt 50 ]]")
        #expect(s == .success)
    }

    @Test func shortCircuitAnd() async throws {
        // RHS shouldn't be touched if LHS is false.
        let cap = makeShell()
        let s = try await cap.shell.run("[[ -e /nope && nonsense -gt z ]]")
        #expect(s == .failure,
                "short-circuit prevents the bad integer compare from erroring")
    }

    // MARK: !

    @Test func bangNegates() async throws {
        let cap = makeShell()
        let s = try await cap.shell.run("[[ ! -e /no/such ]]")
        #expect(s == .success)
    }

    @Test func bangBeforeBinary() async throws {
        let cap = makeShell()
        let s = try await cap.shell.run("[[ ! 1 -eq 2 ]]")
        #expect(s == .success)
    }

    // MARK: Grouping

    @Test func parenthesesGroup() async throws {
        let cap = makeShell()
        let s = try await cap.shell.run("[[ ( 1 -eq 1 || 2 -eq 3 ) && 5 -lt 10 ]]")
        #expect(s == .success)
    }

    // MARK: Integration with control flow

    @Test func ifWithDoubleBracket() async throws {
        let cap = makeShell()
        cap.shell.environment["NAME"] = "alpha"
        try await cap.shell.run("""
            if [[ "$NAME" == a* ]]; then
              echo starts-a
            else
              echo other
            fi
            """)
        #expect(cap.stdout == "starts-a\n")
    }

    @Test func whileWithDoubleBracket() async throws {
        let cap = makeShell()
        cap.shell.environment["i"] = "0"
        try await cap.shell.run("""
            while [[ $i -lt 3 ]]; do
              echo $i
              i=$((i+1))
            done
            """)
        #expect(cap.stdout == "0\n1\n2\n")
    }
}
