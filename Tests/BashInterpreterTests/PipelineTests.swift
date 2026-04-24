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
            shell.stdout(shell.stdin.uppercased())
            return .success
        }
        return cap
    }

    func testTwoStagePipelinePassesStdout() throws {
        let cap = makeShellWithUpper()
        try cap.shell.run("echo hello | upper")
        XCTAssertEqual(cap.stdout, "HELLO\n")
    }

    func testThreeStagePipeline() throws {
        let cap = makeShellWithUpper()
        cap.shell.register(name: "twice") { _, shell in
            shell.stdout(shell.stdin + shell.stdin)
            return .success
        }
        try cap.shell.run("echo hi | upper | twice")
        XCTAssertEqual(cap.stdout, "HI\nHI\n")
    }

    func testFirstStageStdinIsInitialShellStdin() throws {
        let cap = makeShellWithUpper()
        cap.shell.stdin = "start\n"
        // `cat`-like closure that echoes its stdin.
        cap.shell.register(name: "readin") { _, shell in
            shell.stdout(shell.stdin)
            return .success
        }
        try cap.shell.run("readin | upper")
        XCTAssertEqual(cap.stdout, "START\n")
    }

    func testExitStatusIsFromLastStage() throws {
        let cap = makeShellWithUpper()
        let status = try cap.shell.run("true | false")
        XCTAssertEqual(status, .failure)
    }

    func testBangInvertsPipelineStatus() throws {
        let cap = makeShellWithUpper()
        XCTAssertEqual(try cap.shell.run("! true | false"), .success)
        XCTAssertEqual(try cap.shell.run("! true | true"),  .failure)
    }

    func testDollarQuestionAfterPipeline() throws {
        let cap = makeShellWithUpper()
        try cap.shell.run("true | false; echo $?")
        XCTAssertEqual(cap.stdout, "1\n")
    }

    func testStdinAfterPipelineRestored() throws {
        let cap = makeShellWithUpper()
        cap.shell.stdin = "keep"
        try cap.shell.run("echo hi | upper")
        XCTAssertEqual(cap.shell.stdin, "keep",
                       "pipeline should not leak its stdin changes")
    }

    func testPipelineInsideIfCondition() throws {
        let cap = makeShellWithUpper()
        try cap.shell.run("""
            if echo hi | upper; then
              echo ok
            fi
            """)
        XCTAssertEqual(cap.stdout, "HI\nok\n")
    }

    func testPipeAnd_MergesStderr() throws {
        let cap = CapturingShell()
        // Producer writes to both stdout and stderr.
        cap.shell.register(name: "noisy") { _, shell in
            shell.stdout("out\n")
            shell.stderr("err\n")
            return .success
        }
        // Consumer records what it received via stdin.
        cap.shell.register(name: "collect") { _, shell in
            shell.stdout("[\(shell.stdin)]")
            return .success
        }
        try cap.shell.run("noisy |& collect")
        // stderr is merged into collect's stdin, so its stdin should
        // contain both "out\n" and "err\n" (order depends on insertion
        // order by the producer).
        XCTAssertEqual(cap.stdout, "[out\nerr\n]")
    }

    func testPipeWithoutAmpPassesStderrThrough() throws {
        let cap = CapturingShell()
        cap.shell.register(name: "noisy") { _, shell in
            shell.stdout("out\n")
            shell.stderr("err\n")
            return .success
        }
        cap.shell.register(name: "collect") { _, shell in
            shell.stdout("[\(shell.stdin)]")
            return .success
        }
        try cap.shell.run("noisy | collect")
        // stderr flows around the pipe to the real stderr.
        XCTAssertEqual(cap.stdout, "[out\n]")
        XCTAssertEqual(cap.stderr, "err\n")
    }
}
