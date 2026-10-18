import Testing
import Foundation
@testable import BashInterpreter

/// `UID`, `EUID` and `PPID` are read-only, as in bash: assigning one
/// fails with `NAME: readonly variable`, and an assignment-only command
/// drops the rest of the top-level command. SwiftBash used to accept
/// the assignment silently.
@Suite(.timeLimit(.minutes(1))) struct ReadonlyVariableTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        cap.shell.environment.workingDirectory = "/"
        cap.shell.installShellBuiltin(name: "capture") { _ in
            Shell.bashCurrent.stdout(await Shell.bashCurrent.stdin.readAllString())
            return .success
        }
        return cap
    }

    @Test func identityVariablesAreReadOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            UID=5 echo prefix; echo "st=$?"
            f() { local EUID=1; echo "local st=$?"; }; f
            declare PPID=1; echo "declare st=$?"
            export UID=1; echo "export st=$?"
            unset EUID; echo "unset st=$?"
            for PPID in 1 2; do echo body; done; echo "for st=$?"
            read UID <<< 4; echo "read st=$?"
            printf -v UID x; echo "printf st=$?"
            (( UID = 3 )); echo "arith st=$?"
            let EUID++; echo "let st=$?"
            [ "$UID" = "$EUID" ] && echo unchanged
            UID=5; echo "not reached"
            """#)
        #expect(cap.stdout == """
            prefix
            st=0
            local st=1
            declare st=1
            export st=1
            unset st=1
            for st=1
            read st=1
            printf st=1
            arith st=1
            let st=1
            unchanged

            """)
        #expect(cap.stderr == """
            swift-bash: line 1: UID: readonly variable
            swift-bash: line 2: local: EUID: readonly variable
            swift-bash: line 3: declare: PPID: readonly variable
            swift-bash: line 4: UID: readonly variable
            swift-bash: line 5: unset: EUID: cannot unset: readonly variable
            swift-bash: line 6: PPID: readonly variable
            swift-bash: line 7: UID: readonly variable
            swift-bash: line 8: UID: readonly variable
            swift-bash: line 9: UID: readonly variable
            swift-bash: line 10: EUID: readonly variable
            swift-bash: line 12: UID: readonly variable

            """)
        #expect(cap.shell.lastExitStatus == .failure)
    }

    /// `read` fills the names before a read-only one; `local UID`
    /// fails even without a value; `UID=(1) cmd` still runs `cmd`.
    @Test func readOnlyTargetsAmongOthers() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            read first UID last <<< "1 2 3"; echo "st=$? [$first] [$last]"
            f() { local UID; echo "local st=$?"; local EUID x=1; echo "st=$? x=$x"; }; f
            UID=(1) echo ok; echo "st=$?"
            declare -a y=(1) UID=(x)
            echo "declare st=$? ${y[0]} ${UID[1]}"
            export UID=(x)
            echo "export st=$?"
            declare -a PPID=($(echo expanded >&2))
            declare -A EUID; echo "declare -A st=$?"
            OPTIND=1; getopts a UID -a; echo "getopts st=$? OPTIND=$OPTIND"
            OPTIND=1; getopts a UID; echo "getopts st=$? OPTIND=$OPTIND"
            """#)
        #expect(cap.stdout == """
            st=1 [1] []
            local st=1
            st=1 x=1
            ok
            st=0
            declare st=1 1\u{20}
            export st=1
            declare -A st=0
            getopts st=2 OPTIND=2
            getopts st=1 OPTIND=1

            """)
        #expect(cap.stderr == """
            swift-bash: line 1: UID: readonly variable
            swift-bash: line 2: local: UID: readonly variable
            swift-bash: line 2: local: EUID: readonly variable
            swift-bash: line 3: UID: readonly variable
            swift-bash: line 4: UID: readonly variable
            swift-bash: line 6: UID: readonly variable
            expanded
            swift-bash: line 8: PPID: readonly variable
            swift-bash: line 10: UID: readonly variable
            swift-bash: line 11: UID: readonly variable

            """)
    }

    /// As in bash, a read-only assignment drops the rest of the
    /// top-level command; the next line runs with `$?` = 1.
    @Test func readOnlyAssignmentsDropTheRestOfTheCommand() async throws {
        for script in ["UID=(1 2)", "PPID[1]=2", "EUID+=1", "x=1 UID=2", "echo $((UID=3))",
                       "declare -a UID=(x)", "export UID=(x)"] {
            let cap = makeShell()
            try await cap.shell.run(script + "; echo dropped\necho \"next $?\"")
            #expect(cap.stdout == "next 1\n", "\(script)")
            #expect(cap.stderr.hasSuffix("readonly variable\n"), "\(script)")
        }
    }

    /// Bash assigns left to right, so names before the read-only one
    /// keep their values; a prefix assignment is scoped as usual.
    @Test func assignmentsBeforeAReadOnlyOneStay() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            x=1 UID=2 y=3
            echo "[$x] [$y]"
            a=1 UID=2 b=3 true
            echo "[$a] [$b]"
            c=1 UID=(1) d=2
            echo "[$c] [$d]"
            """#)
        #expect(cap.stdout == "[1] []\n[] []\n[1] []\n")
    }

    /// A discard skips the ERR trap; a failing command still fires it,
    /// and the trap leaves `$?` as that command set it.
    @Test func aDiscardSkipsTheErrTrap() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            trap 'echo "ERR $?"' ERR
            UID=1
            echo "a $?"
            (exit 3)
            echo "b $?"
            """#)
        #expect(cap.stdout == "a 1\nERR 3\nb 3\n")
    }

    /// Like any scalar, `UID` reads as a one-element array.
    @Test func identityVariablesAsArrays() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            x=a
            echo "${#x[@]} ${x[0]} [${x[@]}] [${!x[@]}] [${x[@]:+set}]"
            [ "${UID[0]}" = "$UID" ] && [ "${UID[*]}" = "$UID" ] && echo same
            echo "${#EUID[@]} [${!PPID[@]}] [${RANDOM[@]:+set}] [${PPID[@]:0:1}]"
            """#)
        #expect(cap.stdout == "1 a [a] [0] [set]\nsame\n1 [0] [set] [0]\n")
    }

    /// What "the rest of the command" is, checked against bash 5.2:
    /// a function call or group is dropped whole; `source`, `eval` and
    /// a trap go on with their own next line; a subshell, `$(…)` or
    /// pipeline stage ends with status 1; `((…))`-style loops only
    /// fail; `set -e` exits.
    @Test func whatADiscardDrops() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data("echo lib1; UID=1; echo lib1-same\necho lib2\n".utf8),
            to: "/lib.sh", append: false)
        try await cap.shell.run(#"""
            f() { UID=1; echo in-f; }
            f; echo f-same
            { UID=2; echo in-group; }; echo group-same
            while true; do UID=1; echo loop; break; done; echo loop-same
            g() { declare -a UID=(x); echo in-g; }; g; echo g-same
            h() { declare -g -a UID=(x); echo in-h; }; h; echo h-same
            source /lib.sh; echo source-same
            eval 'UID=1; echo eval-same
            echo eval-l2'; echo eval-after
            ( UID=1; echo sub-same
            echo sub-l2 ); echo "sub st=$?"
            x=$(UID=1; echo cs); echo "cs=[$x] st=$?"
            echo pipe | { UID=1; capture; }; echo "pipe st=$?"
            for ((PPID=0;;)); do echo body; done; echo "for st=$?"
            trap 'UID=1; echo trap-same' EXIT
            set -e
            UID=1
            echo not-under-e
            """#)
        #expect(cap.stdout == """
            in-g
            g-same
            lib1
            lib2
            source-same
            eval-l2
            eval-after
            sub st=1
            cs=[] st=1
            pipe st=1
            for st=1

            """)
        #expect(cap.shell.lastExitStatus == .failure)
    }
}
