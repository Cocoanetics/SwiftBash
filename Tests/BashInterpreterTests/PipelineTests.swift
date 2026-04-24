import XCTest
@testable import BashInterpreter

/// Tests for the sequential-buffered pipeline executor. These exercise
/// just the stock built-ins (no BashCommandKit dependency) — one
/// closure-based command acts as a tee to prove stdin flows through.
final class PipelineTests: XCTestCase {

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

    func testTwoStagePipelinePassesStdout() async throws {
        let cap = makeShellWithUpper()
        try await cap.shell.run("echo hello | upper")
        XCTAssertEqual(cap.stdout, "HELLO\n")
    }

    func testThreeStagePipeline() async throws {
        let cap = makeShellWithUpper()
        cap.shell.register(name: "twice") { _, shell in
            let input = await shell.stdin.readAllString()
            shell.stdout(input + input)
            return .success
        }
        try await cap.shell.run("echo hi | upper | twice")
        XCTAssertEqual(cap.stdout, "HI\nHI\n")
    }

    func testFirstStageStdinIsInitialShellStdin() async throws {
        let cap = makeShellWithUpper()
        cap.shell.stdin = .string("start\n")
        cap.shell.register(name: "readin") { _, shell in
            let input = await shell.stdin.readAllString()
            shell.stdout(input)
            return .success
        }
        try await cap.shell.run("readin | upper")
        XCTAssertEqual(cap.stdout, "START\n")
    }

    func testExitStatusIsFromLastStage() async throws {
        let cap = makeShellWithUpper()
        let status = try await cap.shell.run("true | false")
        XCTAssertEqual(status, .failure)
    }

    func testBangInvertsPipelineStatus() async throws {
        let cap = makeShellWithUpper()
        do { let _s = try await cap.shell.run("! true | false"); XCTAssertEqual(_s, .success) }
        do { let _s = try await cap.shell.run("! true | true"); XCTAssertEqual(_s, .failure) }
    }

    func testDollarQuestionAfterPipeline() async throws {
        let cap = makeShellWithUpper()
        try await cap.shell.run("true | false; echo $?")
        XCTAssertEqual(cap.stdout, "1\n")
    }

    func testStdinAfterPipelineRestored() async throws {
        let cap = makeShellWithUpper()
        let keep = InputSource.string("keep")
        cap.shell.stdin = keep
        try await cap.shell.run("echo hi | upper")
        // The outer shell's stdin reference should be exactly what we set
        // before the pipeline — the executor restores it afterwards.
        let leftover = await cap.shell.stdin.readAllString()
        XCTAssertEqual(leftover, "keep",
                       "pipeline should not leak its stdin changes")
    }

    func testPipelineInsideIfCondition() async throws {
        let cap = makeShellWithUpper()
        try await cap.shell.run("""
            if echo hi | upper; then
              echo ok
            fi
            """)
        XCTAssertEqual(cap.stdout, "HI\nok\n")
    }

    func testPipeAnd_MergesStderr() async throws {
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
        XCTAssertEqual(cap.stdout, "[out\nerr\n]")
    }

    func testPipeWithoutAmpPassesStderrThrough() async throws {
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
        XCTAssertEqual(cap.stdout, "[out\n]")
        XCTAssertEqual(cap.stderr, "err\n")
    }
}
