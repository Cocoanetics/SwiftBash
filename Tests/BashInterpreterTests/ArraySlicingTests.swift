import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct ArraySlicingTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: Slicing — ${arr[@]:offset:length}

    @Test func sliceOffsetAndLength() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c d e)
            echo "${arr[@]:1:2}"
            """)
        #expect(cap.stdout == "b c\n")
    }

    @Test func sliceOffsetOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c d e)
            echo "${arr[@]:2}"
            """)
        #expect(cap.stdout == "c d e\n")
    }

    @Test func sliceNegativeOffset() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c d e)
            echo "${arr[@]: -2}"
            """)
        #expect(cap.stdout == "d e\n")
    }

    @Test func sliceNegativeLength() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c d e)
            echo "${arr[@]:1:-1}"
            """)
        #expect(cap.stdout == "b c d\n")
    }

    @Test func sliceStarUsesIFS() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        try await cap.shell.run(#"""
            arr=(a b c d e)
            echo "${arr[*]:1:3}"
            """#)
        #expect(cap.stdout == "b:c:d\n")
    }

    @Test func sliceBeyondLengthIsEmpty() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c)
            echo "[${arr[@]:10:5}]"
            """)
        #expect(cap.stdout == "[]\n")
    }

    @Test func appendThenIndexAssign() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c)
            arr+=(d e)
            arr[6]=LATE
            echo "${arr[@]}"
            echo "count=${#arr[@]}"
            """)
        // Sparse: gap at index 5 disappears from `${arr[@]}`.
        // count is the SET-slot count, not max-index+1.
        #expect(cap.stdout == "a b c d e LATE\ncount=6\n")
    }
}
