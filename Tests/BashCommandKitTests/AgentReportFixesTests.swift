import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// End-to-end coverage for the five small interpreter gaps surfaced by
/// an in-process coding-agent run that surfaced via a triage report —
/// `${var:$i:1}` substring expansion, `set -euo pipefail` combined
/// flags, `bash -n` / `bash -x` mode parsing, `/usr/bin/env` absolute-
/// path dispatch, and `sed --version`. Each scenario reproduces the
/// failure mode and asserts the fixed behaviour.
@Suite(.timeLimit(.minutes(1))) struct AgentReportFixesTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: - Substring with $var offset

    @Test func substringOffsetWithDollarVar() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"text=hello; i=1; echo "${text:$i:3}""#)
        #expect(cap.stdout == "ell\n")
    }

    @Test func substringArithmeticOffsetAndLength() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; echo "${text:1+1:3-1}""#)
        #expect(cap.stdout == "cd\n")
    }

    @Test func substringOffsetOnly() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"text=abcdef; echo "${text:2}""#)
        #expect(cap.stdout == "cdef\n")
    }

    // MARK: - set -euo pipefail combined-flag form

    @Test func setEuoPipefailParses() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -euo pipefail; echo ok")
        #expect(cap.stdout == "ok\n")
        #expect(cap.stderr.isEmpty)
    }

    @Test func plusEuoPipefailParses() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -euo pipefail; set +euo pipefail; echo ok")
        #expect(cap.stdout == "ok\n")
        #expect(cap.stderr.isEmpty)
    }

    // MARK: - bash -n / -x flag parsing

    @Test func bashDashNAcceptsScriptArg() async throws {
        let cap = makeShell()
        // `bash -n FILE` reads but doesn't execute. We use /dev/stdin
        // to avoid needing a real file path.
        try await cap.shell.run("echo 'echo hidden' | bash -n /dev/stdin")
        // `-n` skipped execution: stdout should be empty even though
        // the script body is a valid `echo`. (Previously this errored
        // out with "No such file or directory" on `-n`.)
        #expect(cap.stdout == "")
        #expect(cap.stderr.isEmpty)
    }

    @Test func bashDashXRunsScript() async throws {
        let cap = makeShell()
        try await cap.shell.run("echo 'echo ran' | bash -x /dev/stdin")
        #expect(cap.stdout == "ran\n")
    }

    @Test func bashUnknownFlagErrors() async throws {
        let cap = makeShell()
        try await cap.shell.run("bash -Z; echo done=$?")
        #expect(cap.stderr.contains("invalid option"))
        #expect(cap.stdout.contains("done=2"))
    }

    // MARK: - Absolute-path dispatch via BinCatalog

    @Test func slashBinBashVersionRuns() async throws {
        let cap = makeShell()
        try await cap.shell.run("/bin/bash --version")
        #expect(cap.stdout.contains("bash"))
        #expect(cap.stderr.isEmpty)
    }

    @Test func slashUsrBinFalseRuns() async throws {
        let cap = makeShell()
        try await cap.shell.run("/usr/bin/false; echo $?")
        #expect(cap.stdout == "1\n")
    }

    // MARK: - sed --version

    @Test func sedVersion() async throws {
        let cap = makeShell()
        try await cap.shell.run("sed --version")
        #expect(cap.stdout.contains("sed"))
        #expect(cap.stderr.isEmpty)
    }
}
