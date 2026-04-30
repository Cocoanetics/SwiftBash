import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct PatchCommandTests {

    private func makeShellWithDir() -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "patch-\(UUID())"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }
    private func cleanup(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    #if !os(Windows)
    @Test func basicPatch() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "alpha\nbeta\ngamma\n".write(toFile: dir + "/f.txt",
                                         atomically: true, encoding: .utf8)
        let patch = """
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         alpha
        -beta
        +BETA
         gamma
        """
        try patch.write(toFile: dir + "/p.diff", atomically: true, encoding: .utf8)
        try await cap.shell.run("patch -i p.diff")
        let updated = try String(contentsOfFile: dir + "/f.txt", encoding: .utf8)
        #expect(updated == "alpha\nBETA\ngamma\n")
    }
    #endif

    #if !os(Windows)
    @Test func appendingHunk() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "one\ntwo\n".write(toFile: dir + "/f.txt",
                                atomically: true, encoding: .utf8)
        let patch = """
        --- a/f.txt
        +++ b/f.txt
        @@ -1,2 +1,3 @@
         one
         two
        +three
        """
        try patch.write(toFile: dir + "/p.diff", atomically: true, encoding: .utf8)
        try await cap.shell.run("patch -i p.diff")
        let updated = try String(contentsOfFile: dir + "/f.txt", encoding: .utf8)
        #expect(updated == "one\ntwo\nthree\n")
    }
    #endif

    #if !os(Windows)
    @Test func reversePatch() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "one\nNEW\ntwo\n".write(toFile: dir + "/f.txt",
                                    atomically: true, encoding: .utf8)
        let patch = """
        --- a/f.txt
        +++ b/f.txt
        @@ -1,2 +1,3 @@
         one
        +NEW
         two
        """
        try patch.write(toFile: dir + "/p.diff", atomically: true, encoding: .utf8)
        try await cap.shell.run("patch -R -i p.diff")
        let updated = try String(contentsOfFile: dir + "/f.txt", encoding: .utf8)
        #expect(updated == "one\ntwo\n")
    }
    #endif

    @Test func dryRunDoesNotWrite() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "x\n".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
        let patch = """
        --- a/f.txt
        +++ b/f.txt
        @@ -1,1 +1,1 @@
        -x
        +y
        """
        try patch.write(toFile: dir + "/p.diff", atomically: true, encoding: .utf8)
        try await cap.shell.run("patch --dry-run -i p.diff")
        let unchanged = try String(contentsOfFile: dir + "/f.txt", encoding: .utf8)
        #expect(unchanged == "x\n")
    }

    #if !os(Windows)
    @Test func patchFromStdin() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try "a\nb\nc\n".write(toFile: dir + "/f.txt",
                              atomically: true, encoding: .utf8)
        let patch = """
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        """
        try patch.write(toFile: dir + "/p.diff", atomically: true, encoding: .utf8)
        try await cap.shell.run("cat p.diff | patch")
        let updated = try String(contentsOfFile: dir + "/f.txt", encoding: .utf8)
        #expect(updated == "a\nB\nc\n")
    }
    #endif
}
