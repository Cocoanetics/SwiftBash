import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct FindAdvancedTests {

    private func makeShell() -> (CapturingShell, String) {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        let dir = NSTemporaryDirectory() + "find-adv-\(UUID())"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    @Test func sizePredicateBytes() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try Data(repeating: 0x41, count: 100).write(to: URL(fileURLWithPath: dir + "/small"))
        try Data(repeating: 0x42, count: 5000).write(to: URL(fileURLWithPath: dir + "/big"))
        try await cap.shell.run("find . -size +1000c -type f")
        // big is >1000 bytes, small isn't
        #expect(cap.stdout.contains("big"))
        #expect(!cap.stdout.contains("small"))
    }

    @Test func sizePredicateKib() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: dir + "/four"))
        try await cap.shell.run("find . -size 4k -type f")
        #expect(cap.stdout.contains("four"))
    }

    @Test func mtimeRecent() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch fresh; find . -mtime -1 -type f")
        // Just-created file should be < 1 day old.
        #expect(cap.stdout.contains("fresh"))
    }

    @Test func mmin() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch new; find . -mmin -5 -type f")
        #expect(cap.stdout.contains("new"))
    }

    @Test func permExact() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        _ = FileManager.default.createFile(atPath: dir + "/f", contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: dir + "/f")
        try await cap.shell.run("find . -perm 644 -type f")
        #expect(cap.stdout.contains("f"))
    }

    @Test func permAllOf() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        _ = FileManager.default.createFile(atPath: dir + "/f", contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir + "/f")
        try await cap.shell.run("find . -perm -700 -type f")
        // 755 has all bits in 700 set
        #expect(cap.stdout.contains("f"))
    }

    @Test func permAnyOf() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        _ = FileManager.default.createFile(atPath: dir + "/f", contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: dir + "/f")
        try await cap.shell.run("find . -perm /111 -type f")
        // 600 has no execute bits, so /111 should not match.
        // Filter out the prompt-ish "f\n" by checking the trimmed form.
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(!lines.contains(where: { $0.hasSuffix("f") }))
    }

    @Test func regexPredicate() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch foo123 bar; find . -regex '.*foo[0-9]+'")
        #expect(cap.stdout.contains("foo123"))
        #expect(!cap.stdout.contains("bar"))
    }

    @Test func iregexPredicate() async throws {
        let (cap, dir) = makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("touch FooBar; find . -iregex '.*foobar'")
        #expect(cap.stdout.contains("FooBar"))
    }
}
