#if !os(Android)
import Foundation
import Testing
import SSHKeygenCommand
@testable import BashInterpreter
import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct GitSigningTests {

    /// Match the CLI's two sandbox doors: bash's mounted filesystem and
    /// the URL gate used by SwiftPorts share the same virtual path mapping.
    private func withSandbox(_ body: (CapturingShell) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signing-\(UUID().uuidString)")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("signing-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let mounted = MountedFileSystem(mounts: [
            .init(virtual: "/batch", host: root.path),
            .init(virtual: "/tmp", host: temp.path)
        ], backing: RealFileSystem())
        let cap = CapturingShell()
        cap.shell.fileSystem = mounted
        cap.shell.sandbox = .confined(to: mounted.mapping, home: "/batch/home", temporaryDirectory: temp)
        cap.shell.environment = .synthetic(hostInfo: .synthetic, workingDirectory: "/batch")
        cap.shell.environment["HOME"] = "/batch/home"
        cap.shell.environment["TMPDIR"] = "/tmp"
        cap.shell.registerStandardCommands()
        #expect(cap.shell.processLauncher is BashProcessLauncher)
        try await body(cap)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path) == [])
    }

    private static let setup = """
        set -e
        mkdir -p ~/.ssh
        git init -b main repo >/dev/null
        cd repo
        git config user.name Test
        git config user.email t@e.com
        git config gpg.format ssh
        git config user.signingkey '~/.ssh/id_sign.pub'
        """

    /// Inject only the passphrase reader; key generation, encryption,
    /// signing and verification still use the real SwiftPorts port.
    private func scriptedKeygen(prompts: OutputSink) -> Command {
        ClosureCommand(name: "ssh-keygen") { argv in
            let code = await SSHKeygenExecutable.run(
                argv: Array(argv.dropFirst()), stdin: Shell.current.stdin,
                stdout: Shell.current.stdout, stderr: Shell.current.stderr,
                passphrasePrompt: { prompt in
                    prompts.write(prompt)
                    #expect(prompt == "Enter passphrase for \"/batch/home/.ssh/id_sign\": ")
                    return "test passphrase"
                })
            return ExitStatus(code)
        }
    }

    @Test(arguments: [false, true])
    func signedCommitsAndTags(encrypted: Bool) async throws {
        try await withSandbox { cap in
            let prompts = OutputSink()
            if encrypted {
                cap.shell.install(scriptedKeygen(prompts: prompts))
            }
            let status = try await cap.shell.run("""
                \(Self.setup)
                which ssh-keygen
                type ssh-keygen
                /usr/bin/ssh-keygen -q -t ed25519 -N '\(encrypted ? "test passphrase" : "")' -f ~/.ssh/id_sign
                git config commit.gpgsign true
                echo "t@e.com $(cat ~/.ssh/id_sign.pub)" > ../allowed
                git config gpg.ssh.allowedSignersFile ../allowed
                echo hi > f
                git add f
                git commit -q -m one
                git verify-commit HEAD 2>../commit-verification
                git tag -s v1 -m v1
                git verify-tag v1 2>../tag-verification
                git log --show-signature --format='%G? %GS' -1 > ../log-verification
                git log -1 --format='%G? %GS'
                git config commit.gpgsign false
                git config user.signingkey '~/.ssh/id_sign'
                git commit -q -S --allow-empty -m two
                git verify-commit HEAD 2>../explicit-verification
                git log -1 --format='%G? %GS'
                """)
            try #require(status == .success, "\(cap.stderr)")
            #expect(cap.stderr == "")
            #expect(cap.stdout == "/usr/bin/ssh-keygen\nssh-keygen is /usr/bin/ssh-keygen\nG t@e.com\nG t@e.com\n")
            prompts.finish()
            #expect(await prompts.readAllString() == String(
                repeating: "Enter passphrase for \"/batch/home/.ssh/id_sign\": ", count: encrypted ? 3 : 0))

            let fileSystem = cap.shell.fileSystem
            let verification = try await fileSystem.readData("/batch/commit-verification")
            let line = try #require(String(data: verification, encoding: .utf8))
            #expect(line.hasPrefix("Good \"git\" signature for t@e.com with ED25519 key SHA256:"))
            #expect(line.split(separator: "\n").count == 1)
            for name in ["tag", "explicit"] {
                #expect(try await fileSystem.readData("/batch/\(name)-verification") == verification)
            }
            #expect(try await fileSystem.readData("/batch/log-verification") == Data((line + "G t@e.com\n").utf8))
            let privateKey = try #require(await fileSystem.metadata("/batch/home/.ssh/id_sign"))
            #expect(privateKey.kind == .file)
            #if !os(Windows)
            #expect(privateKey.mode == 0o600)
            #endif
            #expect(try await fileSystem.metadata("/batch/home/.ssh/id_sign.pub") != nil)
        }
    }

    @Test(arguments: ["ssh", "openpgp"])
    func missingSignerDoesNotWriteCommit(format: String) async throws {
        try await withSandbox { cap in
            let setup = try await cap.shell.run("""
                \(Self.setup)
                ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_sign
                git config gpg.format \(format)
                echo hi > f
                git add f
                """)
            try #require(setup == .success, "\(cap.stderr)")
            cap.shell.uninstall(name: "ssh-keygen")
            let status = try await cap.shell.run("git commit -S -m unsigned")
            #expect(status == ExitStatus(128))
            let expected = format == "ssh"
                ? "error: cannot run ssh-keygen: No such file or directory\nerror: \n"
                : "error: cannot run gpg: No such file or directory\n"
                    + "error: gpg failed to sign the data:\n(no gpg output)\n"
            #expect(cap.stderr == expected + "fatal: failed to write commit object\n")
            #expect(cap.stdout == "")
            #expect(try await cap.shell.fileSystem.metadata("/batch/repo/.git/refs/heads/main") == nil)
        }
    }
}
#endif
