import Testing
import Foundation
@testable import BashInterpreter

/// `UID`, `EUID` and `PPID` are read-only, as in bash: assigning one
/// fails with `NAME: readonly variable`, and an assignment-only command
/// ends the script. SwiftBash used to accept the assignment silently.
@Suite(.timeLimit(.minutes(1))) struct ReadonlyVariableTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        cap.shell.environment.workingDirectory = "/"
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

    @Test func readOnlyAssignmentsEndTheScript() async throws {
        for script in ["UID=(1 2)", "PPID[1]=2", "EUID+=1", "x=1 UID=2", "echo $((UID=3))"] {
            let cap = makeShell()
            try await cap.shell.run(script + "; echo not-reached")
            #expect(cap.stdout == "", "\(script)")
            #expect(cap.stderr.hasSuffix("readonly variable\n"), "\(script)")
        }
    }
}
