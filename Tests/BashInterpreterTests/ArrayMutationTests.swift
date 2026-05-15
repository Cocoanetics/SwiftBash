import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct ArrayMutationTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: Element assignment — arr[N]=v

    @Test func elementAssignmentReplaces() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c)
            arr[1]=BRAVO
            echo "${arr[0]} ${arr[1]} ${arr[2]}"
            """)
        #expect(cap.stdout == "a BRAVO c\n")
    }

    @Test func elementAssignmentBeyondLengthIsSparse() async throws {
        // Sparse: setting [5] doesn't pad indices 2–4 with empties.
        // ${#arr[@]} reports SET slot count, not max-index+1.
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b)
            arr[5]=tail
            echo "count=${#arr[@]}"
            echo "[${arr[3]}]"
            echo "[${arr[5]}]"
            echo "indices=${!arr[@]}"
            """)
        #expect(cap.stdout == "count=3\n[]\n[tail]\nindices=0 1 5\n")
    }

    @Test func elementAssignmentOnFreshNameIsSparse() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr[2]=hello
            echo "[${arr[0]}][${arr[1]}][${arr[2]}]"
            echo "count=${#arr[@]}"
            echo "indices=${!arr[@]}"
            """)
        #expect(cap.stdout == "[][][hello]\ncount=1\nindices=2\n")
    }

    @Test func elementAssignmentExpandsValue() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "world"
        try await cap.shell.run(#"""
            arr=(a b c)
            arr[1]="hello $X"
            echo "${arr[1]}"
            """#)
        #expect(cap.stdout == "hello world\n")
    }

    // MARK: Append — arr+=(items)

    @Test func appendExtendsExisting() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b)
            arr+=(c d)
            echo "${arr[@]}"
            echo "count=${#arr[@]}"
            """)
        #expect(cap.stdout == "a b c d\ncount=4\n")
    }

    @Test func appendOnFreshNameInitialises() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr+=(first)
            arr+=(second third)
            echo "${arr[@]}"
            """)
        #expect(cap.stdout == "first second third\n")
    }

    @Test func appendExpandsItems() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "expanded"
        try await cap.shell.run("""
            arr=(literal)
            arr+=($X "$(echo computed)")
            echo "${arr[0]}|${arr[1]}|${arr[2]}"
            """)
        #expect(cap.stdout == "literal|expanded|computed\n")
    }

    // MARK: ${!arr[@]} — list of indices

    @Test func indicesOfDenseArray() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c)
            echo "${!arr[@]}"
            """)
        #expect(cap.stdout == "0 1 2\n")
    }

    @Test func indicesOfSparseArray() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr[2]=x
            arr[5]=y
            arr[100]=z
            echo "${!arr[@]}"
            """)
        #expect(cap.stdout == "2 5 100\n")
    }

    @Test func indicesOfEmptyArrayIsEmpty() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"echo "[${!nope[@]}]""#)
        #expect(cap.stdout == "[]\n")
    }

    @Test func iterateIndicesQuoted() async throws {
        // "${!arr[@]}" expands to N args — one per set index — so
        // the for-loop iterates N times.
        let cap = makeShell()
        try await cap.shell.run(#"""
            arr=(alpha bravo charlie)
            for i in "${!arr[@]}"; do
              echo "[$i]"
            done
            """#)
        #expect(cap.stdout == "[0]\n[1]\n[2]\n")
    }

    // MARK: ${arr[$k]} — subscript with substitution

    @Test func subscriptWithVariable() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(alpha bravo charlie)
            i=2
            echo "${arr[$i]}"
            """)
        #expect(cap.stdout == "charlie\n")
    }

    @Test func subscriptWithBracedVariable() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(alpha bravo charlie)
            i=1
            echo "${arr[${i}]}"
            """)
        #expect(cap.stdout == "bravo\n")
    }

    @Test func subscriptWithArithmetic() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c d e)
            echo "${arr[$((2 + 1))]}"
            """)
        #expect(cap.stdout == "d\n")
    }

    @Test func subscriptWithCommandSub() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(zero one two)
            echo "${arr[$(echo 1)]}"
            """)
        #expect(cap.stdout == "one\n")
    }

    @Test func iterateAndDereference() async throws {
        // The classic use of ${!arr[@]} + ${arr[$i]}.
        let cap = makeShell()
        try await cap.shell.run(#"""
            arr=(alpha bravo charlie)
            for i in "${!arr[@]}"; do
              echo "$i: ${arr[$i]}"
            done
            """#)
        #expect(cap.stdout == "0: alpha\n1: bravo\n2: charlie\n")
    }

    @Test func associativeSubscriptWithVariable() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            declare -A m
            m[hello]=world
            key=hello
            echo "${m[$key]}"
            """)
        #expect(cap.stdout == "world\n")
    }

    // MARK: original — quoted indices preserve associative keys with spaces

    @Test func quotedIndicesPreserveSpaceyAssocKeys() async throws {
        // Associative array keys may contain spaces — "${!m[@]}"
        // preserves each key as a single arg.
        let cap = makeShell()
        cap.shell.register(name: "args") { argv in
            for (idx, arg) in argv.dropFirst().enumerated() {
                Shell.bashCurrent.stdout("[\(idx + 1)]\(arg)\n")
            }
            Shell.bashCurrent.stdout("count=\(argv.count - 1)\n")
            return .success
        }
        try await cap.shell.run(#"""
            declare -A m
            m["space key"]=v1
            m[plain]=v2
            args "${!m[@]}"
            """#)
        // Order isn't dict-stable, so just check argc.
        #expect(cap.stdout.contains("count=2\n"))
        #expect(cap.stdout.contains("space key"))
        #expect(cap.stdout.contains("plain"))
    }
}
