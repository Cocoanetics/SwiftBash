import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

#if !os(Android)
@Suite(.timeLimit(.minutes(1))) struct NewUtilityCommandsTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    private func makeShellInDir() -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "newutil-\(UUID())"
        try! FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let cap = makeShell()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ p: String) {
        try? FileManager.default.removeItem(atPath: p)
    }

    // MARK: mktemp

    @Test func mktempCreatesAFileAndPrintsItsPath() async throws {
        let cap = makeShell()
        try await cap.shell.run("mktemp")
        let path = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!path.isEmpty)
        let meta = try await cap.shell.fileSystem.metadata(path)
        #expect(meta?.kind == .file)
    }

    @Test func mktempDirectoryCreatesADir() async throws {
        let cap = makeShell()
        try await cap.shell.run("mktemp -d")
        let path = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = try await cap.shell.fileSystem.metadata(path)
        #expect(meta?.kind == .directory)
    }

    @Test func mktempReplacesTrailingXs() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        try await cap.shell.run("mktemp tmpXXXXXX")
        let path = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // The Xs are replaced — none should remain in the leaf.
        let leaf = (path as NSString).lastPathComponent
        #expect(leaf.hasPrefix("tmp"))
        #expect(leaf.count == "tmpXXXXXX".count)
        #expect(!leaf.contains("X"))
    }

    @Test func mktempDryRunDoesNotCreate() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        try await cap.shell.run("mktemp -u tmpXXXXXX")
        let path = cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = try await cap.shell.fileSystem.metadata(path)
        #expect(meta == nil)
    }

    // MARK: truncate

    @Test func truncateExtendsToExactSize() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        try await cap.shell.run("echo abc > f; truncate -s 10 f")
        let data = try await cap.shell.fileSystem.readData(dir + "/f")
        #expect(data.count == 10)
        // Pre-existing prefix preserved, the rest is zero-padded.
        #expect(data.prefix(4) == Data("abc\n".utf8))
        #expect(data.suffix(6) == Data(repeating: 0, count: 6))
    }

    @Test func truncateShrinksContent() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        try await cap.shell.run(
            "echo 'long content' > f; truncate -s 4 f")
        let data = try await cap.shell.fileSystem.readData(dir + "/f")
        #expect(data == Data("long".utf8))
    }

    @Test func truncatePlusGrowsRelative() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        try await cap.shell.run("echo ab > f; truncate -s +5 f")
        let data = try await cap.shell.fileSystem.readData(dir + "/f")
        // "ab\n" (3 bytes) + 5 zero bytes
        #expect(data.count == 8)
    }

    @Test func truncateAcceptsKMGSuffixes() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        try await cap.shell.run("touch f; truncate -s 2K f")
        let data = try await cap.shell.fileSystem.readData(dir + "/f")
        #expect(data.count == 2048)
    }

    @Test func truncateNoCreateSkipsMissingFiles() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        try await cap.shell.run("truncate -c -s 10 missing")
        let meta = try await cap.shell.fileSystem.metadata(dir + "/missing")
        #expect(meta == nil)
    }

    // MARK: groups

    @Test func groupsPrintsPrimaryGroup() async throws {
        let cap = makeShell()
        cap.shell.hostInfo.groupName = "researchers"
        cap.shell.hostInfo.groups = [1000]
        try await cap.shell.run("groups")
        #expect(cap.stdout == "researchers\n")
    }

    @Test func groupsRejectsUnknownUser() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("groups not-a-user")
        #expect(status == .failure)
        #expect(cap.stderr.contains("unknown user"))
    }

    // MARK: link / unlink

    // Android's /data/local/tmp rejects link(2) under the emulator's
    // shell-domain SELinux policy; see lnHardLink. `withKnownIssue`
    // ran the body and hung, so skip outright on Android.
    #if !os(Android)
    @Test func linkCreatesAHardLink() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        try await cap.shell.run("echo hi > a; link a b")
        let data = try await cap.shell.fileSystem.readData(dir + "/b")
        #expect(String(decoding: data, as: UTF8.self) == "hi\n")
    }
    #endif

    @Test func unlinkRemovesAFile() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        try await cap.shell.run("touch victim; unlink victim")
        let meta = try await cap.shell.fileSystem.metadata(dir + "/victim")
        #expect(meta == nil)
    }

    @Test func unlinkRejectsDirectories() async throws {
        let (cap, dir) = makeShellInDir(); defer { cleanup(dir) }
        let status = try await cap.shell.run("mkdir d; unlink d")
        #expect(status == .failure)
        #expect(cap.stderr.contains("is a directory"))
    }

    // MARK: yes

    @Test func yesPipedToHeadProducesNLines() async throws {
        let cap = makeShell()
        try await cap.shell.run("yes | head -n 3")
        #expect(cap.stdout == "y\ny\ny\n")
    }

    @Test func yesAcceptsCustomString() async throws {
        let cap = makeShell()
        try await cap.shell.run("yes hello | head -n 2")
        #expect(cap.stdout == "hello\nhello\n")
    }

    // MARK: catalog wiring

    @Test func newCommandsAppearInUsrBin() async throws {
        let cap = makeShell()
        let entries = try await cap.shell.withCurrent {
            try await cap.shell.fileSystem.list("/usr/bin")
        }
        for name in ["mktemp", "truncate", "groups", "yes"] {
            #expect(entries.contains(name),
                    "expected /usr/bin/\(name); got \(entries)")
        }
        // /bin entries: link and unlink.
        let bin = try await cap.shell.withCurrent {
            try await cap.shell.fileSystem.list("/bin")
        }
        for name in ["link", "unlink"] {
            #expect(bin.contains(name),
                    "expected /bin/\(name); got \(bin)")
        }
    }
}
#endif
