import Testing
import Foundation
@testable import BashInterpreter

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct EnvDefaultsTests {

    // MARK: PATH and friends

    @Test func bareShellHasPathSet() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $PATH")
        #expect(cap.stdout == "/usr/bin:/bin\n")
    }

    @Test func bareShellHasIfsSet() async throws {
        let cap = CapturingShell()
        // Just check the byte-level contents of $IFS directly.
        let ifs = cap.shell.environment.variables["IFS"] ?? ""
        #expect(ifs == " \t\n")
    }

    @Test func bareShellHasOptindSet() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $OPTIND")
        #expect(cap.stdout == "1\n")
    }

    @Test func bareShellHasOstypeAndMachtype() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $OSTYPE/$MACHTYPE/$HOSTTYPE")
        // Synthetic defaults — no host info leaked.
        #expect(cap.stdout == "darwin/arm64-apple-darwin/arm64\n")
    }

    @Test func bareShellHasHomeAndUserAndShell() async throws {
        let cap = CapturingShell()
        // Each of these is checked individually so the test doesn't
        // depend on the unfortunate spelling of `$USER/$SHELL` (where
        // $SHELL itself starts with `/` → a stray double-slash).
        #expect(cap.shell.environment.variables["HOME"] == "/home/user")
        #expect(cap.shell.environment.variables["USER"] == "user")
        #expect(cap.shell.environment.variables["LOGNAME"] == "user")
        #expect(cap.shell.environment.variables["SHELL"] == "/bin/bash")
    }

    @Test func bareShellHasPromptVarsSet() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo "[$PS1][$PS2][$PS4]""#)
        // Literal default prompts; we don't expand the \s\v escapes
        // (we're not interactive) but the strings are present.
        #expect(cap.stdout.contains("PS1") == false)  // the variable, not literal "PS1"
        #expect(cap.stdout.contains("> "))
        #expect(cap.stdout.contains("+ "))
    }

    @Test func bareShellHasShlvl() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("echo $SHLVL")
        #expect(cap.stdout == "1\n")
    }

    @Test func bareShellHasPwdSetToWorkingDirectory() async throws {
        let cap = CapturingShell()
        cap.shell.environment.workingDirectory = "/tmp"
        // PWD only auto-fills if not already set; reset so the init
        // logic matters (CapturingShell defaults Environment() which
        // means PWD is filled from cwd).
        // Verify it tracks cwd at construction time.
        let cap2 = CapturingShell(environment: {
            var e = Environment()
            e.workingDirectory = "/tmp"
            return e
        }())
        try await cap2.shell.run("echo $PWD")
        #expect(cap2.stdout == "/tmp\n")
    }

    // MARK: caller's value wins

    @Test func userSetValueIsNotOverwritten() async throws {
        // If the caller explicitly sets PATH in the supplied env,
        // Shell.init must not stomp on it.
        var env = Environment()
        env.variables["PATH"] = "/custom/bin"
        let cap = CapturingShell(environment: env)
        try await cap.shell.run("echo $PATH")
        #expect(cap.stdout == "/custom/bin\n")
    }

    // MARK: hostInfo sync

    @Test func changingHostInfoUpdatesHostnameAndUser() async throws {
        let cap = CapturingShell()
        var info = cap.shell.hostInfo
        info.hostName = "tron"
        info.userName = "alice"
        info.machine = "x86_64"
        cap.shell.hostInfo = info

        try await cap.shell.run(#"echo "$HOSTNAME/$USER/$LOGNAME/$HOSTTYPE/$MACHTYPE""#)
        #expect(cap.stdout == "tron/alice/alice/x86_64/x86_64-apple-darwin\n")
    }
}
#endif
