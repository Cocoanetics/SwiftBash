import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// Coverage for the four `bash`-mode flags — `-e` (errexit),
/// `-u` (nounset), `-x` (xtrace), `-v` (verbose) — both as
/// `set -X` toggles inside a script and as `bash -X` argv flags on
/// invocation, plus their long-option counterparts via
/// `set -o NAME`.
@Suite(.timeLimit(.minutes(1))) struct ShellModeFlagsTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    // MARK: - errexit (-e)

    @Test func setEAbortsOnFailure() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -e; false; echo after")
        #expect(!cap.stdout.contains("after"))
    }

    @Test func setEStaysIfSucceeds() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -e; true; echo ran")
        #expect(cap.stdout == "ran\n")
    }

    @Test func bashDashEAbortsScript() async throws {
        let cap = makeShell()
        try await cap.shell.run("echo 'false; echo after' | bash -e /dev/stdin")
        #expect(!cap.stdout.contains("after"))
    }

    @Test func setMinusOErrexitAlias() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -o errexit; false; echo after")
        #expect(!cap.stdout.contains("after"))
    }

    // MARK: - nounset (-u)

    @Test func setUErrorsOnUnsetVar() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"set -u; echo "$unset_var"; echo after"#)
        #expect(cap.stderr.contains("unset_var: unbound variable"))
        #expect(!cap.stdout.contains("after"))
    }

    @Test func setUIgnoresSetVar() async throws {
        let cap = makeShell()
        try await cap.shell.run(#"set -u; x=hello; echo "$x""#)
        #expect(cap.stdout == "hello\n")
        #expect(cap.stderr.isEmpty)
    }

    @Test func setUDoesNotAffectDefaultForms() async throws {
        // `${var:-default}` should NOT error under nounset because
        // the user is explicitly defaulting.
        let cap = makeShell()
        try await cap.shell.run(#"set -u; echo "${unset_var:-fallback}""#)
        #expect(cap.stdout == "fallback\n")
        #expect(cap.stderr.isEmpty)
    }

    @Test func bashDashUFromArgv() async throws {
        let cap = makeShell()
        try await cap.shell.run("echo 'echo $missing' | bash -u /dev/stdin 2>&1; echo done=$?")
        #expect(cap.stdout.contains("unbound variable"))
        #expect(cap.stdout.contains("done=1"))
    }

    // MARK: - xtrace (-x)

    @Test func setXEmitsTracePrefix() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -x; echo hello")
        // stdout still gets the command's output...
        #expect(cap.stdout == "hello\n")
        // ...and stderr gets the `+ ` trace prefix.
        #expect(cap.stderr.contains("+ echo hello"))
    }

    @Test func xtraceHonorsPS4() async throws {
        let cap = makeShell()
        try await cap.shell.run("PS4='trace> '; set -x; echo one")
        #expect(cap.stderr.contains("trace> echo one"))
    }

    @Test func xtraceTracesEachCommand() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -x; echo a; echo b")
        // Two trace lines on stderr.
        let count = cap.stderr.components(separatedBy: "+ echo ").count - 1
        #expect(count == 2)
    }

    @Test func bashDashXTracesScript() async throws {
        let cap = makeShell()
        try await cap.shell.run("echo 'echo traced' | bash -x /dev/stdin")
        #expect(cap.stdout == "traced\n")
        #expect(cap.stderr.contains("+ echo traced"))
    }

    @Test func setMinusOXtraceAlias() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -o xtrace; echo named")
        #expect(cap.stderr.contains("+ echo named"))
    }

    // MARK: - verbose (-v)

    @Test func setVEchoesSource() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -v; echo hi")
        #expect(cap.stdout == "hi\n")
        #expect(cap.stderr.contains("echo hi"))
    }

    @Test func setMinusOVerboseAlias() async throws {
        let cap = makeShell()
        try await cap.shell.run("set -o verbose; echo named")
        #expect(cap.stderr.contains("echo named"))
    }
}
