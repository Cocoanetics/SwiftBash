import Testing
import Foundation
@testable import BashInterpreter

@Suite struct DeclarationCommandTests {

    // MARK: declare -a / typeset -a — indexed array literal

    @Test func declareDashAArrayLiteral() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            declare -a a=(10 20 30)
            echo "${#a[@]} ${a[0]} ${a[1]} ${a[2]}"
            """#)
        #expect(cap.stdout == "3 10 20 30\n")
    }

    @Test func typesetDashAArrayLiteral() async throws {
        // typeset is a synonym of declare in bash.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            typeset -a t=(x y z)
            echo "${t[@]}"
            """#)
        #expect(cap.stdout == "x y z\n")
    }

    @Test func declareDashAWithoutLiteral() async throws {
        // `declare -a` without an initializer should still let you
        // assign later.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            declare -a u
            u=(p q r)
            echo "${u[1]}"
            """#)
        #expect(cap.stdout == "q\n")
    }

    // MARK: declare -A — associative array literal

    @Test func declareDashAAssociativeLiteral() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            declare -A m=([alpha]=1 [beta]=22 [gamma]=333)
            echo "${m[alpha]} ${m[beta]} ${m[gamma]}"
            """#)
        #expect(cap.stdout == "1 22 333\n")
    }

    @Test func declareDashAAssociativeAcceptsValueWithEqualsAndSlashes() async throws {
        // Real-world: `[url]=https://x.com/a=b` shouldn't be split at
        // the inner `=`, and `/` in the value passes through fine.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            declare -A m=([url]=https://x.com/a=b [path]=/etc/passwd)
            echo "url=${m[url]}"
            echo "path=${m[path]}"
            """#)
        #expect(cap.stdout == """
            url=https://x.com/a=b
            path=/etc/passwd

            """)
    }

    @Test func declareDashAAssociativeMergedFlags() async throws {
        // bash accepts `-Ar` (or `-rA`) as merged short flags.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            declare -Ar m=([k]=v)
            echo "${m[k]}"
            """#)
        #expect(cap.stdout == "v\n")
    }

    @Test func declareDashAEmptyValue() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            declare -A m=([k]=)
            echo "[${m[k]}]"
            """#)
        #expect(cap.stdout == "[]\n")
    }

    // MARK: scalar `declare x=1 y=2`

    @Test func declareMultipleScalarAssignments() async throws {
        // The other regression my tokenizer change exposed — these
        // used to be silently swallowed as scoped prefix assignments
        // (the assignment-words after `declare` were treated like
        // `IFS=":" cmd` prefix pairs).
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            declare x=1 y=2 z=3
            echo "$x $y $z"
            """#)
        #expect(cap.stdout == "1 2 3\n")
    }

    @Test func localScalarAssignmentInFunction() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            f() {
              local p=10 q=20
              echo "in f: $p $q"
            }
            f
            echo "outside: ${p:-unset} ${q:-unset}"
            """#)
        #expect(cap.stdout == """
            in f: 10 20
            outside: unset unset

            """)
    }

    @Test func exportSetsScalar() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            export FOO=bar
            echo "$FOO"
            """#)
        #expect(cap.stdout == "bar\n")
    }

    // MARK: subshell isolation

    @Test func declareInSubshellDoesNotLeak() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            ( declare -a sub=(x y z); echo "in sub: ${sub[*]}" )
            echo "outside: ${sub:-unset}"
            """#)
        #expect(cap.stdout == """
            in sub: x y z
            outside: unset

            """)
    }

    // MARK: regression — prefix assignments still scoped on
    // *non*-declaration commands.

    @Test func nonDeclarationPrefixAssignmentStillScoped() async throws {
        // The whole point of the executor's prefix-assignment logic is
        // `IFS=":" foo` — must still scope X for the duration of the
        // command, not leak. Make sure my fix didn't regress that.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            X=outer
            X=inner echo "during: $X"
            echo "after: $X"
            """#)
        #expect(cap.stdout == """
            during: outer
            after: outer

            """)
    }

    @Test func nonDeclarationCommandSeesAssignmentWordAsArgvNotPrefix() async throws {
        // Edge case: `printf x=1` — printf isn't a declaration
        // built-in, so `x=1` is just a printf argument string.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            X=before
            printf '%s\n' x=1
            echo "X is still $X"
            """#)
        #expect(cap.stdout == "x=1\nX is still before\n")
    }
}
