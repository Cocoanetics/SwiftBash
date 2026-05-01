import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct ArithIndexingTests {

    // MARK: Read indexed

    @Test func readsIndexedArrayElement() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(10 20 30)
            echo $(( a[1] ))
            """#)
        #expect(cap.stdout == "20\n")
    }

    @Test func indexExpressionIsItselfArithmetic() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(10 20 30 40)
            i=1
            echo $(( a[i + 1] ))
            """#)
        #expect(cap.stdout == "30\n")
    }

    @Test func indexedReadInsideBinaryOp() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(7 11 13)
            echo $(( a[0] * a[2] + a[1] ))
            """#)
        // 7 * 13 + 11 = 102
        #expect(cap.stdout == "102\n")
    }

    @Test func indexedReadInDoubleParenCondition() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(0 0 5)
            if (( a[2] > a[0] )); then
              echo bigger
            else
              echo notbigger
            fi
            """#)
        #expect(cap.stdout == "bigger\n")
    }

    @Test func bashVersinfoIndexedAccess() async throws {
        // The script idiom we care about most.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            (( BASH_VERSINFO[0] >= 4 )) && echo modern
            """#)
        #expect(cap.stdout == "modern\n")
    }

    @Test func unsetArrayElementReadsAsZero() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(1 2 3)
            echo $(( a[10] + 7 ))
            """#)
        #expect(cap.stdout == "7\n")
    }

    @Test func unsetArrayNameReadsAsZero() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo $(( noarr[5] + 1 ))"#)
        #expect(cap.stdout == "1\n")
    }

    // MARK: Indexed inc/dec

    @Test func postfixIncrementOnIndexed() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(10 20)
            echo $(( a[0]++ ))
            echo "${a[0]}"
            """#)
        #expect(cap.stdout == "10\n11\n")
    }

    @Test func prefixIncrementOnIndexed() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(10 20)
            echo $(( ++a[1] ))
            echo "${a[1]}"
            """#)
        #expect(cap.stdout == "21\n21\n")
    }

    @Test func sideEffectOrderingInIndexedRead() async throws {
        // arr[i++] inside arithmetic should advance i once per
        // evaluation, reading the original i for the slot.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(100 200 300)
            i=0
            x=$(( a[i++] ))
            y=$(( a[i++] ))
            echo "$x $y $i"
            """#)
        #expect(cap.stdout == "100 200 2\n")
    }

    // MARK: Indexed assign

    @Test func plainAssignToIndexedSlot() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(1 2 3)
            (( a[5] = 99 ))
            echo "${a[@]}"
            """#)
        #expect(cap.stdout == "1 2 3 99\n")
    }

    @Test func compoundAssignToIndexedSlot() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=(10 20 30)
            (( a[1] += 5 ))
            (( a[2] *= 2 ))
            echo "${a[@]}"
            """#)
        #expect(cap.stdout == "10 25 60\n")
    }

    @Test func indexedAssignmentReturnsTheNewValue() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            a=()
            r=$(( a[0] = 42 ))
            echo "$r ${a[0]}"
            """#)
        #expect(cap.stdout == "42 42\n")
    }

    // MARK: Associative arrays

    @Test func indexedReadOnAssociativeArray() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            declare -A m
            m[7]=21
            echo $(( m[7] ))
            """#)
        #expect(cap.stdout == "21\n")
    }
}
