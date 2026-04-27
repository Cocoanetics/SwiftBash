import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct LsCommandTests {

    private func makeShellWithDir() -> (CapturingShell, String) {
        let dir = NSTemporaryDirectory() + "ls-tests-\(UUID())"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ p: String) {
        try? FileManager.default.removeItem(atPath: p)
    }

    @Test func lsBasic() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("echo a > a.txt; echo b > b.txt; ls")
        #expect(cap.stdout.contains("a.txt"))
        #expect(cap.stdout.contains("b.txt"))
    }

    @Test func lsHidden() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("echo x > .hidden; echo y > visible; ls")
        #expect(cap.stdout == "visible\n")
    }

    @Test func lsAllShowsHidden() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("echo x > .hidden; echo y > visible; ls -a")
        #expect(cap.stdout.contains(".hidden"))
        #expect(cap.stdout.contains("visible"))
        #expect(cap.stdout.contains("./") || cap.stdout.contains(".\n"))
    }

    @Test func lsAlmostAllSkipsDotEntries() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("echo x > .hidden; echo y > visible; ls -A")
        #expect(cap.stdout.contains(".hidden"))
        #expect(cap.stdout.contains("visible"))
        // No "." or ".." line on its own
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(!lines.contains("."))
        #expect(!lines.contains(".."))
    }

    @Test func lsLong() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("echo abc > f.txt; ls -l")
        #expect(cap.stdout.contains("total"))
        #expect(cap.stdout.contains("f.txt"))
        // The file inherits the real-fs default umask (often 0644).
        #expect(cap.stdout.contains("-rw-"))
    }

    @Test func lsLongReflectsActualModeBits() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run(
            "touch a.txt; chmod 700 a.txt; touch b.txt; chmod 644 b.txt; ls -l")
        #expect(cap.stdout.contains("-rwx------"))
        #expect(cap.stdout.contains("-rw-r--r--"))
    }

    @Test func lsLongOwnerComesFromHostInfo() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        cap.shell.hostInfo.userName = "alice"
        cap.shell.hostInfo.groupName = "researchers"
        try await cap.shell.run("touch f.txt; ls -l f.txt")
        #expect(cap.stdout.contains("alice researchers"))
    }

    @Test func lsLaShowsDotAndDotDotAsDirectories() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("ls -la")
        // Both `.` and `..` rendered with directory mode (`d…`),
        // not file mode (`-…`).
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        let dot = lines.first { $0.hasSuffix(" .") || $0.hasSuffix(" ./") }
        let dotDot = lines.first { $0.hasSuffix(" ..") || $0.hasSuffix(" ../") }
        #expect(dot?.first == "d", "`.` not rendered as directory: \(dot ?? "nil")")
        #expect(dotDot?.first == "d", "`..` not rendered as directory: \(dotDot ?? "nil")")
    }

    @Test func lsLongShowsStickyBitOnDir() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir tmp; chmod 1777 tmp; ls -la")
        // `chmod 1777 tmp` → drwxrwxrwt (sticky bit + rwx for everyone).
        #expect(cap.stdout.contains("drwxrwxrwt"),
                "expected sticky-bit dir, got: \(cap.stdout)")
    }

    @Test func lsClassify() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub; echo x > a; ls -F")
        #expect(cap.stdout.contains("sub/"))
        #expect(cap.stdout.contains("a"))
    }

    @Test func lsSortBySize() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run(#"echo a > small; echo "long content here" > big; ls -S"#)
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(lines == ["big", "small"])
    }

    @Test func lsReverse() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("echo x > a; echo x > b; echo x > c; ls -r")
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(lines == ["c", "b", "a"])
    }

    @Test func lsDirectoryOnly() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir sub; ls -d sub")
        #expect(cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "sub")
    }

    @Test func lsRecursive() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        try await cap.shell.run("mkdir -p a/b; echo x > a/file; echo y > a/b/inner; ls -R a")
        #expect(cap.stdout.contains("a:"))
        #expect(cap.stdout.contains("a/b:"))
        #expect(cap.stdout.contains("inner"))
    }

    @Test func lsHumanReadable() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        // Create a file > 1K (2048 bytes of 'A').
        FileManager.default.createFile(
            atPath: dir + "/big",
            contents: Data(repeating: 0x41, count: 2048))
        try await cap.shell.run("ls -lh big")
        #expect(cap.stdout.contains("K"))
    }

    @Test func lsMissingFile() async throws {
        let (cap, dir) = makeShellWithDir(); defer { cleanup(dir) }
        let status = try await cap.shell.run("ls nope")
        #expect(status == .failure)
        #expect(cap.stderr.contains("No such file"))
    }
}
