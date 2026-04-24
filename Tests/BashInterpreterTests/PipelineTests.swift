import Testing
@testable import BashInterpreter

/// Tests for the sequential-buffered pipeline executor. These exercise
/// just the stock built-ins (no BashCommandKit dependency) — one
/// closure-based command acts as a tee to prove stdin flows through.
@Suite struct PipelineTests {

    /// Register a tiny test helper: `upper` reads stdin, upper-cases it,
    /// writes to stdout.
    private func makeShellWithUpper() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.register(name: "upper") { _, shell in
            let input = await shell.stdin.readAllString()
            shell.stdout(input.uppercased())
            return .success
        }
        return cap
    }

    @Test func twoStagePipelinePassesStdout() async throws {
        let cap = makeShellWithUpper()
        try await cap.shell.run("echo hello | upper")
        #expect(cap.stdout == "HELLO\n")
    }

    @Test func threeStagePipeline() async throws {
        let cap = makeShellWithUpper()
        cap.shell.register(name: "twice") { _, shell in
            let input = await shell.stdin.readAllString()
            shell.stdout(input + input)
            return .success
        }
        try await cap.shell.run("echo hi | upper | twice")
        #expect(cap.stdout == "HI\nHI\n")
    }

    @Test func firstStageStdinIsInitialShellStdin() async throws {
        let cap = makeShellWithUpper()
        cap.shell.stdin = .string("start\n")
        cap.shell.register(name: "readin") { _, shell in
            let input = await shell.stdin.readAllString()
            shell.stdout(input)
            return .success
        }
        try await cap.shell.run("readin | upper")
        #expect(cap.stdout == "START\n")
    }

    @Test func exitStatusIsFromLastStage() async throws {
        let cap = makeShellWithUpper()
        let status = try await cap.shell.run("true | false")
        #expect(status == .failure)
    }

    @Test func bangInvertsPipelineStatus() async throws {
        let cap = makeShellWithUpper()
        #expect(try await cap.shell.run("! true | false") == .success)
        #expect(try await cap.shell.run("! true | true") == .failure)
    }

    @Test func dollarQuestionAfterPipeline() async throws {
        let cap = makeShellWithUpper()
        try await cap.shell.run("true | false; echo $?")
        #expect(cap.stdout == "1\n")
    }

    @Test func stdinAfterPipelineRestored() async throws {
        let cap = makeShellWithUpper()
        let keep = InputSource.string("keep")
        cap.shell.stdin = keep
        try await cap.shell.run("echo hi | upper")
        // The outer shell's stdin reference should be exactly what we set
        // before the pipeline — the executor restores it afterwards.
        let leftover = await cap.shell.stdin.readAllString()
        #expect(leftover == "keep",
                "pipeline should not leak its stdin changes")
    }

    @Test func pipelineInsideIfCondition() async throws {
        let cap = makeShellWithUpper()
        try await cap.shell.run("""
            if echo hi | upper; then
              echo ok
            fi
            """)
        #expect(cap.stdout == "HI\nok\n")
    }

    @Test func pipeAndMergesStderr() async throws {
        let cap = CapturingShell()
        // Producer writes to both stdout and stderr.
        cap.shell.register(name: "noisy") { _, shell in
            shell.stdout("out\n")
            shell.stderr("err\n")
            return .success
        }
        // Consumer records what it received via stdin.
        cap.shell.register(name: "collect") { _, shell in
            let input = await shell.stdin.readAllString()
            shell.stdout("[\(input)]")
            return .success
        }
        try await cap.shell.run("noisy |& collect")
        // stderr is merged into collect's stdin, so its stdin should
        // contain both "out\n" and "err\n".
        #expect(cap.stdout == "[out\nerr\n]")
    }

    @Test func pipeWithoutAmpPassesStderrThrough() async throws {
        let cap = CapturingShell()
        cap.shell.register(name: "noisy") { _, shell in
            shell.stdout("out\n")
            shell.stderr("err\n")
            return .success
        }
        cap.shell.register(name: "collect") { _, shell in
            let input = await shell.stdin.readAllString()
            shell.stdout("[\(input)]")
            return .success
        }
        try await cap.shell.run("noisy | collect")
        // stderr flows around the pipe to the real stderr.
        #expect(cap.stdout == "[out\n]")
        #expect(cap.stderr == "err\n")
    }
}
