import Testing
@testable import BashInterpreter

@Suite struct ArrayTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: Definition + indexed access

    @Test func defineAndReadElements() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(alpha bravo charlie)
            echo "${arr[0]} ${arr[1]} ${arr[2]}"
            """)
        #expect(cap.stdout == "alpha bravo charlie\n")
    }

    @Test func elementsPreserveSpacesWhenQuoted() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            arr=(simple "two words" plain)
            echo "[${arr[1]}]"
            """#)
        #expect(cap.stdout == "[two words]\n")
    }

    @Test func indexOutOfBoundsIsEmpty() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            arr=(a b c)
            echo "[${arr[7]}]"
            """#)
        #expect(cap.stdout == "[]\n")
    }

    @Test func bareNameReadsFirstElement() async throws {
        // `$arr` (unsubscripted) reads the first element — bash semantics.
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(first second third)
            echo $arr
            """)
        #expect(cap.stdout == "first\n")
    }

    // MARK: ${#arr[@]} — count

    @Test func arrayCount() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c d e)
            echo ${#arr[@]}
            """)
        #expect(cap.stdout == "5\n")
    }

    @Test func arrayCountStarSameAsAt() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(x y z)
            echo ${#arr[*]}
            """)
        #expect(cap.stdout == "3\n")
    }

    @Test func arrayCountEmpty() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"echo "${#missing[@]}""#)
        #expect(cap.stdout == "0\n")
    }

    @Test func elementLengthViaHashSubscript() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(short medium-string verylongstring)
            echo "${#arr[1]}"
            """)
        #expect(cap.stdout == "13\n")
    }

    // MARK: ${arr[@]} — all elements

    @Test func dollarAtAllElementsJoined() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(one two three)
            echo ${arr[@]}
            """)
        #expect(cap.stdout == "one two three\n")
    }

    @Test func quotedDollarAtPreservesSpaces() async throws {
        let cap = makeShell()
        cap.shell.register(name: "args") { argv, shell in
            for (i, a) in argv.dropFirst().enumerated() {
                shell.stdout("[\(i + 1)]\(a)\n")
            }
            shell.stdout("count=\(argv.count - 1)\n")
            return .success
        }
        try await cap.shell.run(#"""
            arr=(simple "two words" plain)
            args "${arr[@]}"
            """#)
        #expect(cap.stdout == "[1]simple\n[2]two words\n[3]plain\ncount=3\n")
    }

    @Test func unquotedDollarAtIFSSplits() async throws {
        let cap = makeShell()
        cap.shell.register(name: "args") { argv, shell in
            shell.stdout("count=\(argv.count - 1)\n")
            return .success
        }
        try await cap.shell.run(#"""
            arr=("a b" c)
            args ${arr[@]}
            """#)
        // Bash: each element gets IFS-split on whitespace.
        // ["a b", "c"] → "a", "b", "c" → 3 args.
        #expect(cap.stdout == "count=3\n")
    }

    @Test func dollarStarJoinsWithIFS() async throws {
        let cap = makeShell()
        cap.shell.environment["IFS"] = ":"
        try await cap.shell.run(#"""
            arr=(one two three)
            echo "${arr[*]}"
            """#)
        #expect(cap.stdout == "one:two:three\n")
    }

    // MARK: For-loop iteration

    @Test func forLoopOverQuotedAt() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            arr=(first "second word" third)
            for x in "${arr[@]}"; do
              echo "[$x]"
            done
            """#)
        #expect(cap.stdout == "[first]\n[second word]\n[third]\n")
    }

    // MARK: Boundary merge inside a word

    @Test func boundaryMergeInWord() async throws {
        let cap = makeShell()
        cap.shell.register(name: "args") { argv, shell in
            for (i, a) in argv.dropFirst().enumerated() {
                shell.stdout("[\(i + 1)]\(a)\n")
            }
            return .success
        }
        try await cap.shell.run(#"""
            arr=(a b c)
            args "pre-${arr[@]}-post"
            """#)
        #expect(cap.stdout == "[1]pre-a\n[2]b\n[3]c-post\n")
    }

    // MARK: Element substitution forms

    @Test func defaultValueOnElement() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            arr=(only)
            echo "[${arr[1]:-fallback}]"
            """#)
        #expect(cap.stdout == "[fallback]\n")
    }

    // MARK: Mixed with substitutions in items

    @Test func itemValuesGetExpanded() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "expanded"
        try await cap.shell.run("""
            arr=(literal $X "$(echo computed)")
            echo "${arr[0]}|${arr[1]}|${arr[2]}"
            """)
        #expect(cap.stdout == "literal|expanded|computed\n")
    }

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

    @Test func elementAssignmentBeyondLengthPads() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b)
            arr[5]=tail
            echo "count=${#arr[@]}"
            echo "[${arr[3]}]"
            echo "[${arr[5]}]"
            """)
        #expect(cap.stdout == "count=6\n[]\n[tail]\n")
    }

    @Test func elementAssignmentOnFreshName() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr[2]=hello
            echo "[${arr[0]}][${arr[1]}][${arr[2]}]"
            echo "count=${#arr[@]}"
            """)
        #expect(cap.stdout == "[][][hello]\ncount=3\n")
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

    @Test func appendThenIndexAssign() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            arr=(a b c)
            arr+=(d e)
            arr[6]=LATE
            echo "${arr[@]}"
            echo "count=${#arr[@]}"
            """)
        // Note: real bash uses sparse arrays — index 5 (gap between
        // appended `e` and arr[6]=LATE) wouldn't appear in
        // `${arr[@]}`. We pad with an empty element instead, so the
        // join shows "a b c d e  LATE" (two spaces). Bash compat
        // here would need a sparse-array refactor; the tradeoff is
        // documented.
        #expect(cap.stdout == "a b c d e  LATE\ncount=7\n")
    }
}
