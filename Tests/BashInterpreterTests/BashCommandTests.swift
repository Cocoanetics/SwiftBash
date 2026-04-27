import Testing
import Foundation
@testable import BashInterpreter

@Suite struct BashCommandTests {

    // MARK: --version / --help

    @Test func versionPrintsBanner() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("bash --version")
        #expect(cap.stdout.contains("GNU bash"))
        #expect(cap.stdout.contains("4.4.20"))
        #expect(cap.stdout.contains("swift-bash"))
    }

    @Test func helpPrintsUsage() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("bash --help")
        #expect(cap.stdout.contains("Usage: bash"))
        #expect(cap.stdout.contains("-c COMMAND"))
    }

    // MARK: -c forms

    @Test func dashCRunsInlineCommand() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("bash -c 'echo hi'")
        #expect(cap.stdout == "hi\n")
    }

    @Test func dashCSetsZeroAndPositionalParams() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(
            #"bash -c 'echo "$0|$1|$2|$#"' label first second"#)
        // $0 = label, $1 = first, $2 = second, $# = 2
        #expect(cap.stdout == "label|first|second|2\n")
    }

    @Test func dashCDefaultZeroIsCommandName() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"bash -c 'echo $0'"#)
        #expect(cap.stdout == "bash\n")
    }

    @Test func dashCMissingArgIsError() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run("bash -c")
        #expect(status.code == 2)
        #expect(cap.stderr.contains("requires an argument"))
    }

    // MARK: bash FILE [args…]

    @Test func bashRunsScriptFile() async throws {
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory() + "bash-test-\(UUID())"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.sh"
        try "echo from-file: $1\n".write(
            toFile: path, atomically: true, encoding: .utf8)

        try await cap.shell.run("bash \(path) hello")
        #expect(cap.stdout == "from-file: hello\n")
    }

    @Test func bashStripsShebangFromScriptFile() async throws {
        // A script file starting with `#!/usr/bin/env bash` would
        // otherwise be parsed as a comment, but let's make sure we
        // strip it cleanly so the next line runs unaffected.
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory() + "bash-shebang-\(UUID())"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.sh"
        try "#!/usr/bin/env bash\necho post-shebang\n".write(
            toFile: path, atomically: true, encoding: .utf8)

        try await cap.shell.run("bash \(path)")
        #expect(cap.stdout == "post-shebang\n")
    }

    @Test func bashMissingFileExits127() async throws {
        let cap = CapturingShell()
        let status = try await cap.shell.run(
            "bash /tmp/no-such-script-\(UUID())")
        #expect(status.code == 127)
        #expect(cap.stderr.contains("No such file or directory"))
    }

    // MARK: subshell isolation

    @Test func subshellMutationsDoNotLeak() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            X=parent
            bash -c 'X=child; echo "in child: $X"'
            echo "in parent: $X"
            """#)
        #expect(cap.stdout == "in child: child\nin parent: parent\n")
    }

    @Test func exitFromInsideBashCommandStaysScoped() async throws {
        // `bash -c 'exit 7'` returns status 7 to the caller — it
        // does NOT terminate the outer shell.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            bash -c 'exit 7'
            echo "after: $?"
            """#)
        #expect(cap.stdout == "after: 7\n")
    }

    // MARK: aliases

    @Test func shAliasWorks() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("sh -c 'echo from-sh'")
        #expect(cap.stdout == "from-sh\n")
    }

    @Test func dashAliasWorks() async throws {
        let cap = CapturingShell()
        try await cap.shell.run("dash -c 'echo from-dash'")
        #expect(cap.stdout == "from-dash\n")
    }

    @Test func shDefaultZeroIsSh() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"sh -c 'echo $0'"#)
        #expect(cap.stdout == "sh\n")
    }

    // MARK: env vars

    @Test func bashVersionEnvVarIsSet() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo $BASH_VERSION"#)
        #expect(cap.stdout == "4.4.20(1)-release\n")
    }

    @Test func bashPathEnvVarIsSet() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(#"echo $BASH"#)
        #expect(cap.stdout == "/bin/bash\n")
    }

    @Test func bashVersinfoArrayIsSet() async throws {
        let cap = CapturingShell()
        try await cap.shell.run(
            #"echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}""#)
        #expect(cap.stdout == "4.4\n")
    }

    @Test func bashVersinfoExposedToScript() async throws {
        // The canonical way scripts gate on bash 4+ features.
        let cap = CapturingShell()
        try await cap.shell.run(#"""
            if (( BASH_VERSINFO[0] >= 4 )); then
              echo "modern bash"
            else
              echo "old bash"
            fi
            """#)
        #expect(cap.stdout == "modern bash\n")
    }

    // MARK: catalog wiring

    @Test func bashShDashAppearInBin() async throws {
        let shell = Shell(fileSystem: InMemoryFileSystem())
        let entries = try await shell.withCurrent {
            try await shell.fileSystem.list("/bin")
        }
        for name in ["bash", "sh", "dash"] {
            #expect(entries.contains(name),
                    "expected /bin/\(name); got \(entries)")
        }
    }
}
