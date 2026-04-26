import Testing
@testable import BashInterpreter

@Suite struct AssociativeArrayTests {

    private func makeShell() -> CapturingShell { CapturingShell() }

    // MARK: declare -A + element get / set

    @Test func declareThenSetAndGet() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            declare -A m
            m[name]=oliver
            m[city]=berlin
            echo "${m[name]} from ${m[city]}"
            """)
        #expect(cap.stdout == "oliver from berlin\n")
    }

    @Test func missingKeyIsEmpty() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            declare -A m
            m[a]=1
            echo "[${m[nope]}]"
            """#)
        #expect(cap.stdout == "[]\n")
    }

    @Test func overwriteExistingKey() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            declare -A m
            m[k]=first
            m[k]=second
            echo "${m[k]}"
            """)
        #expect(cap.stdout == "second\n")
    }

    // MARK: count

    @Test func countOfAssociative() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            declare -A m
            m[a]=1
            m[b]=2
            m[c]=3
            echo "${#m[@]}"
            """)
        #expect(cap.stdout == "3\n")
    }

    // MARK: keys via ${!m[@]}

    @Test func keysListing() async throws {
        // Dict ordering isn't stable, so we just check the SET of
        // keys via a custom collector command.
        let cap = makeShell()
        cap.shell.register(name: "collect") { argv in
            let keys = Set(argv.dropFirst())
            let sorted = keys.sorted()
            Shell.current.stdout(sorted.joined(separator: ",") + "\n")
            return .success
        }
        try await cap.shell.run("""
            declare -A m
            m[red]=r
            m[green]=g
            m[blue]=b
            collect ${!m[@]}
            """)
        #expect(cap.stdout == "blue,green,red\n")
    }

    @Test func keysCountMatchesInsertions() async throws {
        let cap = makeShell()
        cap.shell.register(name: "argc") { argv in
            Shell.current.stdout("\(argv.count - 1)\n")
            return .success
        }
        try await cap.shell.run("""
            declare -A m
            m[a]=1
            m[b]=2
            m[c]=3
            argc ${!m[@]}
            """)
        #expect(cap.stdout == "3\n")
    }

    // MARK: values via ${m[@]}

    @Test func valuesCountMatchesInsertions() async throws {
        let cap = makeShell()
        cap.shell.register(name: "argc") { argv in
            Shell.current.stdout("\(argv.count - 1)\n")
            return .success
        }
        try await cap.shell.run("""
            declare -A m
            m[a]=alpha
            m[b]=bravo
            argc ${m[@]}
            """)
        #expect(cap.stdout == "2\n")
    }

    // MARK: declare -A doesn't conflict with indexed

    @Test func separateNamespaces() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            indexed=(a b c)
            declare -A m
            m[a]=1
            echo "${indexed[0]} ${m[a]} ${#indexed[@]} ${#m[@]}"
            """)
        #expect(cap.stdout == "a 1 3 1\n")
    }

    // MARK: Type conversion

    @Test func declareAfterScalarReplaces() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            x=scalar
            declare -A x
            x[k]=value
            echo "[${x[k]}]"
            echo "[${x[0]}]"
            """)
        // Bare scalar is gone after `declare -A`, replaced with assoc.
        #expect(cap.stdout == "[value]\n[]\n")
    }

    @Test func keyWithSpecialChars() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            declare -A m
            m[hello.world]=ok
            echo "${m[hello.world]}"
            """#)
        #expect(cap.stdout == "ok\n")
    }

    // MARK: Smoke — usage in pipeline

    @Test func valuesFedThroughCommand() async throws {
        let cap = makeShell()
        cap.shell.register(name: "join") { argv in
            Shell.current.stdout(argv.dropFirst().sorted().joined(separator: ",") + "\n")
            return .success
        }
        try await cap.shell.run("""
            declare -A m
            m[a]=apple
            m[b]=banana
            m[c]=cherry
            join ${m[@]}
            """)
        #expect(cap.stdout == "apple,banana,cherry\n")
    }
}
