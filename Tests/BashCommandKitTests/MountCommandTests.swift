import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite(.timeLimit(.minutes(1))) struct MountCommandTests {

    @Test func listsVirtualMountsOrderedByPath() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mount-\(UUID().uuidString)")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mount-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: tmp)
        }

        let mounted = MountedFileSystem(
            mounts: [
                .init(virtual: "/", host: sandbox.path, readOnly: true),
                .init(virtual: "/home",
                      host: sandbox.appendingPathComponent("home").path),
                .init(virtual: "/tmp", host: tmp.path)
            ],
            backing: RealFileSystem())
        let cap = CapturingShell()
        cap.shell.fileSystem = mounted
        cap.shell.registerStandardCommands()

        let status = try await cap.shell.run("mount")
        #expect(status == .success)

        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        // Ordered by virtual path; read-only root carries (ro).
        #expect(lines[0].contains(" on / type sandbox (ro)"))
        #expect(lines[1].contains(" on /home type sandbox (rw)"))
        #expect(lines[2].contains(" on /tmp type sandbox (rw)"))
        // The host directory is named as the "device".
        #expect(lines[2].hasPrefix(tmp.path))
    }

    @Test func nonMountedShellPrintsNothing() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        let status = try await cap.shell.run("mount")
        #expect(status == .success)
        #expect(cap.stdout.isEmpty)
    }

    @Test func operandsAreIgnored() async throws {
        let cap = CapturingShell()
        cap.shell.registerStandardCommands()
        // A plain in-memory shell: still succeeds, ignoring the operand.
        let status = try await cap.shell.run("mount -l /somewhere")
        #expect(status == .success)
    }
}
