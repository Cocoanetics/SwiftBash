import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct TrapCommandTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: EXIT

    @Test func exitTrapRunsOnNormalCompletion() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "bye"' EXIT
            echo "hi"
            """)
        #expect(cap.stdout == "hi\nbye\n")
    }

    @Test func exitTrapRunsAfterExitCommand() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "cleanup"' EXIT
            echo "before"
            exit 0
            echo "never"
            """)
        #expect(cap.stdout == "before\ncleanup\n")
    }

    @Test func exitTrapRunsAfterErrexit() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "cleanup"' EXIT
            set -e
            false
            echo "never"
            """)
        #expect(cap.stdout == "cleanup\n")
    }

    @Test func exitTrapClearedByDash() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "bye"' EXIT
            trap - EXIT
            echo "hi"
            """)
        #expect(cap.stdout == "hi\n")
    }

    @Test func exitTrapWithSignalNumberZero() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "bye"' 0
            echo "hi"
            """)
        #expect(cap.stdout == "hi\nbye\n")
    }

    // MARK: ERR

    @Test func errTrapRunsOnFailure() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "err"' ERR
            false
            echo "after"
            """)
        #expect(cap.stdout == "err\nafter\n")
    }

    @Test func errTrapDoesntFireOnSuccess() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "err"' ERR
            true
            echo "after"
            """)
        #expect(cap.stdout == "after\n")
    }

    @Test func errTrapDoesntFireInIfCond() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "err"' ERR
            if false; then echo "yes"; else echo "no"; fi
            """)
        #expect(cap.stdout == "no\n")
    }

    @Test func errTrapPlusErrexit() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "trapped"' ERR
            set -e
            false
            echo "never"
            """)
        // ERR fires THEN errexit halts.
        #expect(cap.stdout == "trapped\n")
    }

    // MARK: DEBUG

    @Test func debugTrapFiresBeforeEachCommand() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "d"' DEBUG
            echo "a"
            echo "b"
            """)
        // The trap registration is itself a command; subsequent
        // simple commands each fire DEBUG once before themselves.
        #expect(cap.stdout == "d\na\nd\nb\n")
    }

    // MARK: Listing

    @Test func bareTrapListsHandlers() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo bye' EXIT
            trap 'echo err' ERR
            trap
            """)
        #expect(cap.stdout.contains("trap -- 'echo bye' EXIT"))
        #expect(cap.stdout.contains("trap -- 'echo err' ERR"))
    }

    @Test func dashPLLists() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo bye' EXIT
            trap -p EXIT
            """)
        #expect(cap.stdout.contains("trap -- 'echo bye' EXIT"))
    }

    @Test func dashLListsSignalNames() async throws {
        let cap = makeShell()
        try await cap.shell.run("trap -l")
        #expect(cap.stdout.contains("EXIT"))
        #expect(cap.stdout.contains("ERR"))
        #expect(cap.stdout.contains("INT"))
    }

    @Test func sigIntPrefixIsAccepted() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo got-int' SIGINT
            trap -p INT
            """)
        #expect(cap.stdout.contains("INT"))
    }

    @Test func invalidSignalReportsError() async throws {
        let cap = makeShell()
        try await cap.shell.run("trap 'echo nope' WAT")
        #expect(cap.stderr.contains("invalid signal"))
    }

    // MARK: Re-entrancy

    @Test func errTrapDoesntRecurseOnFailure() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            trap 'echo "in-trap"; false' ERR
            false
            echo "after"
            """)
        // The `false` inside the trap shouldn't re-trigger ERR.
        #expect(cap.stdout == "in-trap\nafter\n")
    }
}
