import Testing
import Foundation
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct TestCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        cap.shell.environment.workingDirectory = "/"
        return cap
    }

    private func runReturning(_ source: String) async throws -> ExitStatus {
        let cap = makeShell()
        return try await cap.shell.run(source)
    }

    // MARK: nullary / single-arg

    @Test func emptyTestIsFalse() async throws {
        let s = try await runReturning("test")
        #expect(s == .failure)
    }

    @Test func nonEmptyArgIsTrue() async throws {
        let s = try await runReturning("test foo")
        #expect(s == .success)
    }

    @Test func emptyArgIsFalse() async throws {
        let s = try await runReturning("test \"\"")
        #expect(s == .failure)
    }

    // MARK: file ops

    @Test func dashEFile() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data(), to: "/file", append: false)
        let s = try await cap.shell.run("[ -e /file ]")
        #expect(s == .success)
    }

    @Test func dashFFile() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data(), to: "/file", append: false)
        try await cap.shell.fileSystem.createDirectory("/dir", intermediates: false)
        #expect(try await cap.shell.run("[ -f /file ]") == .success)
        #expect(try await cap.shell.run("[ -f /dir ]") == .failure)
    }

    @Test func dashDDir() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.createDirectory("/d", intermediates: false)
        try await cap.shell.fileSystem.writeData(Data(), to: "/f", append: false)
        #expect(try await cap.shell.run("[ -d /d ]") == .success)
        #expect(try await cap.shell.run("[ -d /f ]") == .failure)
    }

    @Test func dashSNonEmpty() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data("hi".utf8), to: "/big", append: false)
        try await cap.shell.fileSystem.writeData(
            Data(), to: "/empty", append: false)
        #expect(try await cap.shell.run("[ -s /big ]") == .success)
        #expect(try await cap.shell.run("[ -s /empty ]") == .failure)
    }

    @Test func missingFileFails() async throws {
        let s = try await runReturning("[ -e /no/such ]")
        #expect(s == .failure)
    }

    // MARK: string ops

    @Test func equality() async throws {
        #expect(try await runReturning("[ foo = foo ]") == .success)
        #expect(try await runReturning("[ foo = bar ]") == .failure)
        #expect(try await runReturning("[ foo != bar ]") == .success)
    }

    @Test func dashZAndDashN() async throws {
        #expect(try await runReturning("[ -z \"\" ]") == .success)
        #expect(try await runReturning("[ -z foo ]") == .failure)
        #expect(try await runReturning("[ -n foo ]") == .success)
        #expect(try await runReturning("[ -n \"\" ]") == .failure)
    }

    // MARK: integer ops

    @Test func integerComparisons() async throws {
        #expect(try await runReturning("[ 5 -eq 5 ]") == .success)
        #expect(try await runReturning("[ 5 -ne 5 ]") == .failure)
        #expect(try await runReturning("[ 5 -lt 10 ]") == .success)
        #expect(try await runReturning("[ 5 -le 5 ]") == .success)
        #expect(try await runReturning("[ 10 -gt 5 ]") == .success)
        #expect(try await runReturning("[ 5 -ge 6 ]") == .failure)
    }

    @Test func integerOpRequiresNumber() async throws {
        let cap = makeShell()
        let s = try await cap.shell.run("[ foo -eq 5 ]")
        #expect(s == ExitStatus(2))
        #expect(cap.stderr.contains("integer expression"))
    }

    // MARK: logical

    @Test func negation() async throws {
        #expect(try await runReturning("[ ! -e /no/such ]") == .success)
        #expect(try await runReturning("[ ! foo = foo ]") == .failure)
    }

    @Test func andOr() async throws {
        #expect(try await runReturning("[ 5 -gt 1 -a 5 -lt 10 ]") == .success)
        #expect(try await runReturning("[ 5 -gt 100 -o 5 -lt 10 ]") == .success)
        #expect(try await runReturning("[ 5 -gt 100 -o 5 -lt 1 ]") == .failure)
    }

    @Test func parenthesisedGrouping() async throws {
        #expect(try await runReturning("[ \\( 1 -lt 2 \\) -a 3 -lt 4 ]")
                == .success)
    }

    // MARK: `[ ]` requires closing bracket

    @Test func leftBracketWithoutCloseFailsLoudly() async throws {
        let cap = makeShell()
        let s = try await cap.shell.run("[ -f /file")
        #expect(s == ExitStatus(2))
        #expect(cap.stderr.contains("missing"))
    }

    // MARK: integration

    @Test func ifTestExists() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data(), to: "/marker", append: false)
        try await cap.shell.run("""
            if [ -f /marker ]; then echo found
            else echo missing
            fi
            """)
        #expect(cap.stdout == "found\n")
    }

    @Test func whileTestLoop() async throws {
        let cap = makeShell()
        cap.shell.environment["i"] = "0"
        try await cap.shell.run("""
            while [ "$i" -lt 3 ]; do
              echo "i=$i"
              i=$((i+1))
            done
            """)
        #expect(cap.stdout == "i=0\ni=1\ni=2\n")
    }

    @Test func testCommandSameAsBracket() async throws {
        // `test` and `[` are aliases.
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data(), to: "/f", append: false)
        #expect(try await cap.shell.run("test -f /f") == .success)
        #expect(try await cap.shell.run("[ -f /f ]") == .success)
    }

    @Test func unsetVarComparesAsEmpty() async throws {
        // Idiomatic safety: `[ -z "$X" ]` when X is unset.
        let cap = makeShell()
        let s = try await cap.shell.run("[ -z \"$NOPE\" ]")
        #expect(s == .success)
    }
}
#endif
