import Testing
@testable import BashInterpreter

/// `$(…)`, `` `…` ``, `<(…)` and `>(…)` run in a subshell, as in bash.
/// They used to run in the calling shell, so `dir=$(cd sub && pwd)`
/// moved the script and `v=$(exit 1)` ended it.
@Suite(.timeLimit(.minutes(1))) struct CommandSubstitutionSubshellTests {

    /// A shell on an in-memory filesystem with a `/sub` directory (so
    /// `cd` behaves the same on every platform), and `capture`, which
    /// copies stdin to stdout (the interpreter tests have no `cat`).
    private func makeShell() async throws -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        try await cap.shell.fileSystem.createDirectory("/sub", intermediates: true)
        cap.shell.environment.workingDirectory = "/"
        cap.shell.installShellBuiltin(name: "capture") { _ in
            let input = await Shell.bashCurrent.stdin.readAllString()
            Shell.bashCurrent.stdout(input)
            return .success
        }
        return cap
    }

    // MARK: Isolation

    @Test func assignmentsInsideDoNotLeak() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"x=1; y=$(x=2; echo $x); echo "x=$x y=$y""#)
        #expect(cap.stdout == "x=1 y=2\n")
    }

    @Test func cdInsideDoesNotLeak() async throws {
        let cap = try await makeShell()
        try await cap.shell.run("z=$(cd /sub; pwd); pwd; echo $z")
        #expect(cap.stdout == "/\n/sub\n")
    }

    @Test func functionDefinitionsDoNotLeak() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(
            "f() { echo outer; }; w=$(f() { echo inner; }; f); f; echo $w")
        #expect(cap.stdout == "outer\ninner\n")
    }

    @Test func capturedStdoutIsNotATerminal() async throws {
        let cap = CapturingShell()
        cap.shell.stdoutIsTTY = true
        try await cap.shell.run(
            "echo $([ -t 1 ] && echo tty || echo notty); [ -t 1 ] && echo tty")
        #expect(cap.stdout == "notty\ntty\n")
    }

    @Test func outputProcessSubstitutionKeepsTheTerminal() async throws {
        // `>(cmd)` writes to the shell's own stdout, terminal and all.
        let cap = CapturingShell()
        cap.shell.stdoutIsTTY = true
        try await cap.shell.run(
            "echo hi > >(read v; [ -t 1 ] && echo \"tty $v\" || echo \"notty $v\")")
        #expect(cap.stdout == "tty hi\n")
    }

    @Test func heredocSubstitutionIsASubshell() async throws {
        let cap = try await makeShell()
        try await cap.shell.run("""
            capture <<EOF
            $(x=3; cd /sub; echo in; exit 2)
            EOF
            echo "x=$x"; pwd
            """)
        #expect(cap.stdout == "in\nx=\n/\n")
    }

    @Test func inputProcessSubstitutionIsASubshell() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(
            #"capture < <(x=9; cd /sub; echo in); echo "x=$x"; pwd"#)
        #expect(cap.stdout == "in\nx=\n/\n")
    }

    @Test func outputProcessSubstitutionIsASubshell() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(
            #"echo hi > >(read v; echo "got $v"; x=leaked); echo "x=$x""#)
        #expect(cap.stdout == "got hi\nx=\n")
    }

    @Test func aTrapsSubstitutionDoesNotRefireTheTrap() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            trap 'x=$(echo hi)' DEBUG
            echo done
            trap - DEBUG
            trap 'y=$(false)' ERR
            false
            echo after
            """#)
        #expect(cap.stdout == "done\nafter\n")
    }

    @Test func getoptsInASubshellContinuesFromOurPosition() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            set -- -abc
            getopts abc o; echo "first $o"
            x=$(getopts abc o; echo "$o"); echo "sub $x"
            getopts abc o; echo "next $o"
            """#)
        #expect(cap.stdout == "first a\nsub b\nnext b\n")
    }

    // MARK: exit and $?

    @Test func exitEndsOnlyTheSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"v=$(echo out; exit 3); echo "st=$? v=$v"; echo after"#)
        #expect(cap.stdout == "st=3 v=out\nafter\n")
    }

    @Test func backtickExitEndsOnlyTheSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"x=`exit 4`; echo "st=$?""#)
        #expect(cap.stdout == "st=4\n")
    }

    @Test func assignmentOnlyCommandFailsWithItsSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            v=$(false); echo "st=$?"
            out=$(false) || echo or-branch
            if out=$(echo hi; false); then :; else echo "else $out"; fi
            """#)
        #expect(cap.stdout == "st=1\nor-branch\nelse hi\n")
    }

    @Test func statusFollowsBashRules() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=$(exit 2) b=$(exit 5); echo "last sub: $?"
            false; x=1; echo "plain assignment: $?"
            x=$(exit 6) true; echo "with a command: $?"
            echo "same command: $(exit 3) $?"
            """#)
        #expect(cap.stdout == """
            last sub: 5
            plain assignment: 0
            with a command: 0
            same command:  3

            """)
    }

    @Test func errexitStopsAtAFailedAssignment() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("set -e; x=$(false); echo unreachable")
        #expect(cap.stdout == "")
        #expect(status == .failure)
    }

    @Test func commandSubstitutionsRunWithoutErrexit() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            set -e
            x=$(false; echo kept); echo "x=$x"
            y=`false; echo kept`; echo "y=$y"
            """#)
        #expect(cap.stdout == "x=kept\ny=kept\n")
    }

    @Test func inheritErrexitKeepsItInCommandSubstitutions() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run(
            "set -e; shopt -s inherit_errexit; x=$(false; echo kept); echo unreachable")
        #expect(cap.stdout == "")
        #expect(status == .failure)
    }

    @Test func subshellsInAnIgnoredErrexitContextIgnoreItToo() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            set -e
            shopt -s inherit_errexit
            x=$(false; echo kept) || :; echo "x=$x"
            ( false; echo "group kept" ) || :
            echo end
            """#)
        #expect(cap.stdout == "x=kept\ngroup kept\nend\n")
    }

    @Test func processSubstitutionsKeepErrexit() async throws {
        let cap = try await makeShell()
        try await cap.shell.run("set -e; capture < <(false; echo dropped); echo after")
        #expect(cap.stdout == "after\n")
    }

    @Test func strayBreakInASubstitutionWarns() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"x=$(break); echo "st=$?""#)
        #expect(cap.stdout == "st=0\n")
        #expect(cap.stderr.contains("break: only meaningful"))
    }

    @Test func breakInASubstitutionInsideALoopIsQuiet() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(
            #"for i in 1 2; do v=$(break; echo in); echo "loop $i v=$v"; done"#)
        #expect(cap.stdout == "loop 1 v=\nloop 2 v=\n")
        #expect(cap.stderr == "")
    }

    // MARK: Subshells keep the function frame

    @Test func returnInsideAFunctionEndsOnlyTheSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            f() { x=$(echo a; return 3; echo b); echo "st=$? x=$x"; }
            f; echo after
            """#)
        #expect(cap.stdout == "st=3 x=a\nafter\n")
        #expect(cap.stderr == "")
    }

    @Test func localWorksInAFunctionsSubstitution() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"f() { y=$(local l=5; echo $l); echo "y=$y"; }; f"#)
        #expect(cap.stdout == "y=5\n")
        #expect(cap.stderr == "")
    }

    @Test func returnInsideAFunctionsSubshellGroup() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"f() { (return 4); echo "st=$?"; }; f"#)
        #expect(cap.stdout == "st=4\n")
        #expect(cap.stderr == "")
    }

    @Test func returnInsideAFunctionsPipelineStage() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            f() {
                printf 'a\nb\n' | while read l; do
                    [ "$l" = a ] && return 7
                    echo "saw $l"
                done
                echo "pipeline st=$?"
            }
            f
            """#)
        #expect(cap.stdout == "pipeline st=7\n")
        #expect(cap.stderr == "")
    }

    @Test func exitInAPipelineStageEndsOnlyTheStage() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"exit 3 | capture; echo "st=$? survived""#)
        #expect(cap.stdout == "st=0 survived\n")
    }

    // MARK: One-command pipelines stay in the shell

    @Test func negatedAssignmentKeepsItsValue() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            if ! out=$(echo hi; false); then echo "failed with $out"; fi
            ! x=kept; echo "x=$x"
            """#)
        #expect(cap.stdout == "failed with hi\nx=kept\n")
    }

    @Test func negatedAndTimedCdMoveTheShell() async throws {
        let cap = try await makeShell()
        try await cap.shell.run("! cd /sub; pwd; cd /; time cd /sub 2>/dev/null; pwd")
        #expect(cap.stdout == "/sub\n/sub\n")
    }

    // MARK: Body

    /// A body of several lines runs every one of them; only the first
    /// used to run. An empty body expands to nothing.
    @Test func multiLineBodyRunsEveryLine() async throws {
        let cap = try await makeShell()
        try await cap.shell.run(#"""
            x=$(echo a
            echo b)
            echo "[$x]"
            echo "[$(
              echo c

              echo d
            )]"
            echo `echo e
            echo f`
            capture < <(echo g
            echo h)
            echo "[$( )]"
            """#)
        #expect(cap.stdout == "[a\nb]\n[c\nd]\ne f\ng\nh\n[]\n")
    }
}
