import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

/// `od`'s `-A` / `-N` / `-t` options, exercised with the attached short
/// forms (`-An`, `-tx1`, `-N3`) the report cited — these route through
/// the hand-rolled scanner since the ArgumentParser bridge rejects
/// joined short-option values.
@Suite(.timeLimit(.minutes(1))) struct OdCommandTests {

    private func makeShell() throws -> (CapturingShell, String) {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("od-\(UUID())")
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

    @Test func typeHexBytesNoAddress() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'hello' | od -An -tx1")
        #expect(cap.stdout == " 68 65 6c 6c 6f\n")
    }

    @Test func readLimitTruncates() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'hello' | od -An -tx1 -N3")
        #expect(cap.stdout == " 68 65 6c\n")
    }

    @Test func decimalAddressRadix() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'hi' | od -Ad -tx1")
        #expect(cap.stdout == "0000000 68 69\n0000002\n")
    }

    @Test func signedDecimalBytes() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try Data([0x41, 0xFF]).write(to: URL(fileURLWithPath: dir + "/b"))
        try await cap.shell.run("od -An -td1 b")
        // 0x41 = 65; 0xFF read as a signed byte = -1. Width 4, space-pad.
        #expect(cap.stdout == "   65   -1\n")
    }

    @Test func separatedFormStillWorks() async throws {
        let (cap, dir) = try makeShell(); defer { cleanup(dir) }
        try await cap.shell.run("printf 'hello' | od -A n -t x1")
        #expect(cap.stdout == " 68 65 6c 6c 6f\n")
    }
}
