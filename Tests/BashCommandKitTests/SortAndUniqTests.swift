import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct SortAndUniqTests {

    private func makeShell() throws -> (CapturingShell, String) {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString)
            .appendingPathComponent("sortuniq-\(UUID())")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = dir
        return (cap, dir)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: sort

    @Test func sortDefaultLexicographic() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'banana\\napple\\ncherry\\n' | sort")
        #expect(cap.stdout == "apple\nbanana\ncherry\n")
    }

    @Test func sortUniqueDropsDuplicates() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'b\\na\\nb\\nc\\na\\n' | sort -u")
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func sortNumericTreatsLeadingDigits() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        // Lexicographic: "10" < "2"; numeric: 2 < 10.
        try await cap.shell.run("printf '10\\n2\\n1\\n20\\n' | sort -n")
        #expect(cap.stdout == "1\n2\n10\n20\n")
    }

    @Test func sortReverseFlipsOrder() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'a\\nb\\nc\\n' | sort -r")
        #expect(cap.stdout == "c\nb\na\n")
    }

    @Test func sortRnCombinesNumericAndReverse() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf '5\\n2\\n100\\n10\\n' | sort -rn")
        #expect(cap.stdout == "100\n10\n5\n2\n")
    }

    @Test func sortReadsFiles() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        let dataPath = (dir as NSString).appendingPathComponent("data.txt")
        try "c\na\nb\n".write(toFile: dataPath, atomically: true, encoding: .utf8)
        try await cap.shell.run("sort data.txt")
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func sortMissingFileFails() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        let status = try await cap.shell.run("sort nope.txt")
        #expect(status == .failure)
        #expect(cap.stderr.contains("nope.txt"))
    }

    // MARK: uniq

    @Test func uniqCollapsesAdjacentDuplicates() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'a\\na\\nb\\nb\\nb\\nc\\n' | uniq")
        #expect(cap.stdout == "a\nb\nc\n")
    }

    @Test func uniqOnlyAdjacent() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        // Non-adjacent duplicates are NOT removed; that's `sort -u`.
        try await cap.shell.run(
            "printf 'a\\nb\\na\\n' | uniq")
        #expect(cap.stdout == "a\nb\na\n")
    }

    @Test func uniqDashCPrependsCount() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'a\\na\\na\\nb\\n' | uniq -c")
        // BSD format: 4-char width count, single space, line.
        #expect(cap.stdout == "   3 a\n   1 b\n")
    }

    @Test func uniqAfterSort() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run(
            "printf 'b\\na\\nb\\nc\\na\\n' | sort | uniq -c")
        #expect(cap.stdout == "   2 a\n   2 b\n   1 c\n")
    }
}
