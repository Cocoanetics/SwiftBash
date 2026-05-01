import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct PositionalParametersTests {

    // MARK: $0..$N

    @Test func dollarZeroIsScriptName() async throws {
        let cap = CapturingShell()
        cap.shell.scriptName = "myscript.sh"
        try await cap.shell.run("echo $0")
        #expect(cap.stdout == "myscript.sh\n")
    }

    @Test func dollarOneTwoThree() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["alpha", "bravo", "charlie"]
        try await cap.shell.run("echo $1 $2 $3")
        #expect(cap.stdout == "alpha bravo charlie\n")
    }

    @Test func unsetParamIsEmpty() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["only-one"]
        try await cap.shell.run("echo [$2]")
        #expect(cap.stdout == "[]\n")
    }

    @Test func bracedTenAndAbove() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = (1...12).map { "p\($0)" }
        try await cap.shell.run("echo ${10} ${11} ${12}")
        #expect(cap.stdout == "p10 p11 p12\n")
    }

    // MARK: $#, $@, $*

    @Test func dollarHashIsCount() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["a", "b", "c", "d"]
        try await cap.shell.run("echo $#")
        #expect(cap.stdout == "4\n")
    }

    @Test func dollarHashEmpty() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $#")
        #expect(cap.stdout == "0\n")
    }

    @Test func dollarAtJoinedSpaces() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["one", "two", "three"]
        try await cap.shell.run("echo $@")
        #expect(cap.stdout == "one two three\n")
    }

    @Test func dollarStarJoinedSpaces() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["one", "two", "three"]
        try await cap.shell.run("echo $*")
        #expect(cap.stdout == "one two three\n")
    }

    // MARK: for VAR; do … done

    @Test func forWithoutInIteratesPositional() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["red", "green", "blue"]
        try await cap.shell.run("for c; do echo $c; done")
        #expect(cap.stdout == "red\ngreen\nblue\n")
    }

    @Test func forWithoutInOnEmptyParams() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("for c; do echo $c; done; echo done")
        #expect(cap.stdout == "done\n")
    }

    // MARK: set --

    @Test func setDashDashReplacesPositional() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["old"]
        try await cap.shell.run("set -- a b c; echo $1 $2 $3 $#")
        #expect(cap.stdout == "a b c 3\n")
    }

    @Test func setDashDashEmptyClears() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["x", "y"]
        try await cap.shell.run("set --; echo [$#]")
        #expect(cap.stdout == "[0]\n")
    }

    // MARK: shift

    @Test func shiftDefaultDropsOne() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["a", "b", "c"]
        try await cap.shell.run("shift; echo $1 $2 $#")
        #expect(cap.stdout == "b c 2\n")
    }

    @Test func shiftCountDropsN() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["a", "b", "c", "d"]
        try await cap.shell.run("shift 2; echo $1 $2 $#")
        #expect(cap.stdout == "c d 2\n")
    }

    @Test func shiftBeyondAvailableFails() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["only"]
        let status = try await cap.shell.run("shift 5")
        #expect(status == .failure)
        // Original list is preserved on failure.
        #expect(cap.shell.positionalParameters == ["only"])
    }

    // MARK: word-splitting in for-loop

    @Test func forLoopOverDollarAt() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["one", "two", "three"]
        try await cap.shell.run("for x in $@; do echo [$x]; done")
        #expect(cap.stdout == "[one]\n[two]\n[three]\n")
    }

    // MARK: Inside double-quotes

    @Test func paramsInDoubleQuotedString() async throws {
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["world"]
        try await cap.shell.run(#"echo "hello $1""#)
        #expect(cap.stdout == "hello world\n")
    }

    // MARK: argv-level "$@" splitting

    @Test func dollarAtPreservesEmbeddedSpaces() async throws {
        // The point of "$@": each positional param should be passed
        // through as ONE argv element even when it contains spaces.
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["hello world", "second"]
        cap.shell.register(name: "showargs") { argv in
            for (i, arg) in argv.dropFirst().enumerated() {
                Shell.current.stdout("[\(i + 1)]\(arg)\n")
            }
            return .success
        }
        try await cap.shell.run(#"showargs "$@""#)
        #expect(cap.stdout == "[1]hello world\n[2]second\n")
    }

    @Test func dollarAtUnquotedAlsoSplits() async throws {
        // Unquoted $@ also splits per arg in argv position.
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["one", "two", "three"]
        cap.shell.register(name: "count") { argv in
            Shell.current.stdout("\(argv.count - 1)\n")
            return .success
        }
        try await cap.shell.run("count $@")
        #expect(cap.stdout == "3\n")
    }

    @Test func dollarAtEmptyParamsContributesZeroArgs() async throws {
        let cap = CapturingShell()
        // No positional params set.
        cap.shell.register(name: "count") { argv in
            Shell.current.stdout("\(argv.count - 1)\n")
            return .success
        }
        try await cap.shell.run(#"count "$@""#)
        #expect(cap.stdout == "0\n",
                "$@ with no params should expand to zero args, not one empty")
    }

    @Test func wrapperForwardsArgsVerbatim() async throws {
        // Classic pattern: wrapper "$@" → callee sees the same args.
        let cap = CapturingShell()
        cap.shell.positionalParameters = ["a b", "c"]
        cap.shell.register(name: "echoargs") { argv in
            for arg in argv.dropFirst() {
                Shell.current.stdout("<\(arg)>\n")
            }
            return .success
        }
        try await cap.shell.run(#"echoargs "$@""#)
        #expect(cap.stdout == "<a b>\n<c>\n")
    }
}
