import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct FunctionTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.fileSystem = InMemoryFileSystem()
        cap.shell.environment.workingDirectory = "/"
        return cap
    }

    // MARK: Definition + invocation

    @Test func basicFunction() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            greet() { echo "hello $1"; }
            greet world
            """)
        #expect(cap.stdout == "hello world\n")
    }

    @Test func functionKeywordSyntax() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            function greet { echo hi; }
            greet
            """)
        #expect(cap.stdout == "hi\n")
    }

    @Test func functionSeesOuterEnvironment() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "outer"
        try await cap.shell.run("""
            f() { echo "x is $X"; }
            f
            """)
        #expect(cap.stdout == "x is outer\n")
    }

    @Test func functionMutatesGlobalEnv() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            f() { Y=set-by-f; }
            f
            echo "$Y"
            """)
        #expect(cap.stdout == "set-by-f\n",
                "without `local`, function assignments leak — matches bash")
    }

    @Test func multipleArguments() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            args() { echo "n=$#"; for a; do echo "  [$a]"; done; }
            args one "two three" four
            """)
        #expect(cap.stdout
                == "n=3\n  [one]\n  [two three]\n  [four]\n")
    }

    @Test func dollarAtForwardsExactly() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"""
            wrap() { inner "$@"; }
            inner() { for a; do echo "<$a>"; done; }
            wrap "first arg" second
            """#)
        #expect(cap.stdout == "<first arg>\n<second>\n")
    }

    // MARK: positional params don't leak

    @Test func positionalParamsRestoreAfterCall() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["outer1", "outer2"]
        try await cap.shell.run("""
            f() { echo "inner=$1"; }
            f INNER
            echo "outer=$1"
            """)
        #expect(cap.stdout == "inner=INNER\nouter=outer1\n")
    }

    // MARK: return

    @Test func returnEarlyWithStatus() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            f() { echo before; return 7; echo after; }
            f
            echo "exit=$?"
            """)
        #expect(cap.stdout == "before\nexit=7\n")
    }

    @Test func returnDefaultUsesLastExit() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            f() { false; return; }
            f
            echo "exit=$?"
            """)
        #expect(cap.stdout == "exit=1\n")
    }

    @Test func returnUnwindsThroughLoops() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            f() {
              for i in 1 2 3 4 5; do
                if [ "$i" -eq 3 ]; then return 0; fi
                echo "$i"
              done
              echo NEVER
            }
            f
            """)
        #expect(cap.stdout == "1\n2\n")
    }

    @Test func returnOutsideFunctionWarns() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("return 5")
        #expect(status == .failure)
        #expect(cap.stderr.contains("only `return' from a function"))
    }

    // MARK: local

    @Test func localKeepsVariableScoped() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "outer"
        try await cap.shell.run("""
            f() { local X=inner; echo "in: $X"; }
            f
            echo "out: $X"
            """)
        #expect(cap.stdout == "in: inner\nout: outer\n")
    }

    @Test func localUnsetsByDefault() async throws {
        let cap = makeShell()
        cap.shell.environment["X"] = "outer"
        try await cap.shell.run("""
            f() { local X; echo "[$X]"; }
            f
            echo "[$X]"
            """)
        #expect(cap.stdout == "[]\n[outer]\n")
    }

    @Test func localMultipleNames() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            f() {
              local A=one B=two C=three
              echo "$A $B $C"
            }
            f
            echo "after: [${A-unset}]"
            """)
        #expect(cap.stdout == "one two three\nafter: [unset]\n")
    }

    @Test func localOutsideFunctionFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("local X=hi")
        #expect(status == .failure)
        #expect(cap.stderr.contains("only be used in a function"))
    }

    @Test func nestedFunctionCallsHaveTheirOwnLocals() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            inner() { local X=inner; echo "inner: $X"; }
            outer() { local X=outer; inner; echo "outer: $X"; }
            outer
            echo "global: [${X-unset}]"
            """)
        #expect(cap.stdout
                == "inner: inner\nouter: outer\nglobal: [unset]\n")
    }

    // MARK: source / .

    @Test func sourceRunsFileInCurrentShell() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data("X=from-source\nf() { echo from-fn; }\n".utf8),
            to: "/lib.sh", append: false)
        try await cap.shell.run("""
            source /lib.sh
            echo "$X"
            f
            """)
        #expect(cap.stdout == "from-source\nfrom-fn\n")
    }

    @Test func dotIsAliasForSource() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data("Y=hi\n".utf8), to: "/c.sh", append: false)
        try await cap.shell.run(". /c.sh; echo $Y")
        #expect(cap.stdout == "hi\n")
    }

    @Test func sourcePassesPositionalArgs() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data("echo \"got $1 and $2\"\n".utf8),
            to: "/p.sh", append: false)
        try await cap.shell.run("source /p.sh alpha beta")
        #expect(cap.stdout == "got alpha and beta\n")
    }

    @Test func sourceRestoresPositionalsAfter() async throws {
        let cap = makeShell()
        cap.shell.positionalParameters = ["outer"]
        try await cap.shell.fileSystem.writeData(
            Data("echo \"inner=$1\"\n".utf8),
            to: "/p.sh", append: false)
        try await cap.shell.run(#"""
            source /p.sh inner
            echo "outer=$1"
            """#)
        #expect(cap.stdout == "inner=inner\nouter=outer\n")
    }

    @Test func sourceMissingFileFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("source /no/such/file")
        #expect(status == .failure)
        #expect(cap.stderr.contains("No such"))
    }

    @Test func returnFromSourcedScript() async throws {
        let cap = makeShell()
        try await cap.shell.fileSystem.writeData(
            Data("echo before; return 0; echo after\n".utf8),
            to: "/r.sh", append: false)
        try await cap.shell.run("source /r.sh; echo done")
        #expect(cap.stdout == "before\ndone\n")
    }

    // MARK: Recursion

    @Test func recursiveFunction() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            countdown() {
              local n=$1
              if [ "$n" -le 0 ]; then return; fi
              echo "$n"
              countdown $((n - 1))
            }
            countdown 3
            """)
        #expect(cap.stdout == "3\n2\n1\n")
    }

    // MARK: Function in pipeline

    @Test func functionAsPipelineProducer() async throws {
        let cap = makeShell()
        // Use a closure-registered consumer so we don't depend on
        // BashCommandKit being loaded in BashInterpreter tests.
        cap.shell.register(name: "count") { _ in
            var count = 0
            for await _ in Shell.bashCurrent.stdin.lines { count += 1 }
            Shell.bashCurrent.stdout("\(count)\n")
            return .success
        }
        try await cap.shell.run("""
            three() { echo a; echo b; echo c; }
            three | count
            """)
        #expect(cap.stdout == "3\n")
    }

    // MARK: Functions and registered commands coexist

    @Test func functionShadowsBuiltin() async throws {
        let cap = makeShell()
        try await cap.shell.run("""
            echo() { /bin/echo-replacement "$@"; }
            true
            """)
        // We're not actually invoking the override here — just
        // confirming the parser+interpreter accepts the redefinition.
        #expect(cap.shell.commands["echo"] is FunctionCommand)
    }
}
