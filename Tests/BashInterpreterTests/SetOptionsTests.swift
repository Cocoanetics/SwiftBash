import Testing
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct SetOptionsTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: errexit

    @Test func errexitExitsOnFailure() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -e
            false
            echo "after"
            """)
        // `false` triggered exit; the `echo "after"` never ran.
        #expect(cap.stdout == "")
        #expect(!cap.shell.lastExitStatus.isSuccess)
    }

    @Test func errexitDisabledByDefault() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            false
            echo "after"
            """)
        #expect(cap.stdout == "after\n")
    }

    @Test func errexitOffViaPlusE() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -e
            set +e
            false
            echo "after"
            """)
        #expect(cap.stdout == "after\n")
    }

    @Test func errexitLongName() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -o errexit
            false
            echo "after"
            """)
        #expect(cap.stdout == "")
    }

    @Test func errexitSuppressedInIfCond() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -e
            if false; then echo "yes"; else echo "no"; fi
            echo "after"
            """)
        #expect(cap.stdout == "no\nafter\n")
    }

    @Test func errexitSuppressedInWhileCond() async throws {
        // `((i++))` evaluates to i's pre-value, so the first iteration
        // would return 0 (a "failure" status from arith) and trip
        // errexit. Use pre-increment / explicit assignment instead.
        let cap = makeShell()
        try await cap.shell.run("""
            set -e
            i=0
            while ((i < 3)); do
                i=$((i + 1))
                echo "$i"
            done
            echo "after"
            """)
        #expect(cap.stdout == "1\n2\n3\nafter\n")
    }

    @Test func errexitSuppressedOnLeftOfAndAnd() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -e
            false && echo "skipped"
            echo "after"
            """)
        // `false && …` failure is "checked" by `&&`, no exit.
        #expect(cap.stdout == "after\n")
    }

    @Test func errexitTriggersOnRightOfOrOrFailure() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -e
            false || false
            echo "after"
            """)
        // The final `false` is the chain's terminating command and
        // its failure DOES trigger errexit.
        #expect(cap.stdout == "")
    }

    @Test func errexitSuppressedByBangPipeline() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -e
            ! true
            echo "after"
            """)
        // `! true` returns 1, but `!`-inverted commands skip errexit.
        #expect(cap.stdout == "after\n")
    }

    @Test func errexitInsideFunctionPropagates() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -e
            mywork() {
                false
                echo "inside-after"
            }
            mywork
            echo "outside-after"
            """)
        // The function body's `false` triggers exit.
        #expect(cap.stdout == "")
    }

    @Test func errexitWithExplicitNonZero() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -e
            ( exit 7 )
            echo "after"
            """)
        // The subshell exits 7; errexit triggers in the parent too.
        // (Subshell semantics may differ; the simple check is that
        // the script doesn't reach `echo`.)
        #expect(cap.stdout == "")
    }

    // MARK: pipefail

    @Test func pipefailDefaultUsesLastStage() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            false | true
            echo "$?"
            """)
        #expect(cap.stdout == "0\n")
    }

    @Test func pipefailReturnsRightmostNonZero() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -o pipefail
            false | true
            echo "$?"
            """)
        // `false` failed, last stage succeeded; pipefail makes the
        // pipeline overall fail.
        #expect(cap.stdout == "1\n")
    }

    @Test func pipefailAllSuccessReturnsZero() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -o pipefail
            true | true | true
            echo "$?"
            """)
        #expect(cap.stdout == "0\n")
    }

    @Test func pipefailCombinedWithErrexit() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -eo pipefail
            false | true
            echo "after"
            """)
        // pipefail flips the pipeline status to failure → errexit
        // exits before `echo` runs.
        #expect(cap.stdout == "")
    }

    @Test func pipefailOffViaPlusO() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -o pipefail
            set +o pipefail
            false | true
            echo "$?"
            """)
        #expect(cap.stdout == "0\n")
    }

    // MARK: Combined short flags

    @Test func combinedShortFlags() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -eu
            """)
        #expect(cap.shell.errexit)
        #expect(cap.shell.nounset)
    }

    @Test func unknownShortFlagFails() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -Z")
        #expect(cap.stderr.contains("invalid option"))
    }

    @Test func unknownLongOptionFails() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -o nosuchthing")
        #expect(cap.stderr.contains("invalid option name"))
    }

    // MARK: Positional args still work

    @Test func dashDashStillSetsPositional() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            set -- a b c
            echo "$1 $2 $3"
            """)
        #expect(cap.stdout == "a b c\n")
    }
}
#endif
