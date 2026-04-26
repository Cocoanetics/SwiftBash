import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite struct SortCommandTests {

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        return cap
    }

    private func sort(_ input: String, _ flags: String = "") async throws -> String {
        let cap = makeShell()
        try await cap.shell.run("printf %s '\(input.replacingOccurrences(of: "'", with: "'\\''"))' | sort \(flags)")
        return cap.stdout
    }

    @Test func basic() async throws {
        let out = try await sort("c\nb\na\n")
        #expect(out == "a\nb\nc\n")
    }

    @Test func reverse() async throws {
        let out = try await sort("a\nb\nc\n", "-r")
        #expect(out == "c\nb\na\n")
    }

    @Test func numeric() async throws {
        let out = try await sort("10\n2\n1\n", "-n")
        #expect(out == "1\n2\n10\n")
    }

    @Test func unique() async throws {
        let out = try await sort("a\nb\na\nc\nb\n", "-u")
        #expect(out == "a\nb\nc\n")
    }

    @Test func ignoreCase() async throws {
        let out = try await sort("Banana\napple\nCherry\n", "-f")
        #expect(out == "apple\nBanana\nCherry\n")
    }

    @Test func humanNumeric() async throws {
        let out = try await sort("2K\n5M\n1G\n100\n", "-h")
        #expect(out == "100\n2K\n5M\n1G\n")
    }

    @Test func versionSort() async throws {
        let out = try await sort("v1.10\nv1.2\nv1.1\n", "-V")
        #expect(out == "v1.1\nv1.2\nv1.10\n")
    }

    @Test func monthSort() async throws {
        let out = try await sort("Mar\nJan\nFeb\n", "-M")
        #expect(out == "Jan\nFeb\nMar\n")
    }

    @Test func ignoreLeadingBlanks() async throws {
        let out = try await sort("  banana\napple\n  cherry\n", "-b")
        #expect(out == "apple\n  banana\n  cherry\n")
    }

    @Test func keyByField() async throws {
        let out = try await sort("c 3\nb 1\na 2\n", "-k2,2 -n")
        #expect(out == "b 1\na 2\nc 3\n")
    }

    @Test func customDelimiter() async throws {
        let out = try await sort("a:3\nb:1\nc:2\n", "-t: -k2 -n")
        #expect(out == "b:1\nc:2\na:3\n")
    }

    @Test func keyWithReverseModifier() async throws {
        let out = try await sort("a 1\nb 2\nc 3\n", "-k2nr")
        #expect(out == "c 3\nb 2\na 1\n")
    }

    @Test func multipleKeys() async throws {
        let out = try await sort("b 1\na 2\na 1\n", "-k1,1 -k2n")
        #expect(out == "a 1\na 2\nb 1\n")
    }

    @Test func dictionaryOrder() async throws {
        // -d strips punctuation before comparing.
        // "a-b" → "ab"; "aab" → "aab"; "aab" < "ab" lexically.
        let out = try await sort("a-b\naab\n", "-d")
        #expect(out == "aab\na-b\n")
    }

    @Test func stable() async throws {
        // Lines that compare equal under -k1 should stay in input order.
        let out = try await sort("a 2\na 1\n", "-k1,1 -s")
        #expect(out == "a 2\na 1\n")
    }

    @Test func checkSorted() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("printf 'a\\nb\\nc\\n' | sort -c")
        #expect(status == .success)
    }

    @Test func checkUnsortedFails() async throws {
        let cap = makeShell()
        let status = try await cap.shell.run("printf 'a\\nc\\nb\\n' | sort -c")
        #expect(status == ExitStatus(1))
        #expect(cap.stderr.contains("disorder"))
    }

    @Test func outputFile() async throws {
        let cap = makeShell()
        let dir = NSTemporaryDirectory() + "sort-out-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/result.txt"
        try await cap.shell.run("printf 'b\\na\\n' | sort -o \(out)")
        #expect(cap.stdout == "")
        let written = try String(contentsOfFile: out, encoding: .utf8)
        #expect(written == "a\nb\n")
    }

    @Test func numericReverseCombined() async throws {
        let out = try await sort("1\n10\n2\n", "-rn")
        #expect(out == "10\n2\n1\n")
    }
}
