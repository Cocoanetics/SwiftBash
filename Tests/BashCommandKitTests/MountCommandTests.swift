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
        // Synthetic device label — the host backing path must NOT leak.
        #expect(lines.allSatisfy { $0.hasPrefix("sandbox on ") })
        #expect(!cap.stdout.contains(sandbox.path))
        #expect(!cap.stdout.contains(tmp.path))
    }

    @Test func keepsSelfMountWhereVirtualEqualsHost() async throws {
        // The Linux sandbox mounts /tmp → NSTemporaryDirectory(), which
        // normalises to "/tmp" (virtual == host). That's a genuine mount,
        // not a $TMPDIR real-path alias, so `mount` must still list it.
        let mounted = MountedFileSystem(
            mounts: [
                .init(virtual: "/", host: "/workspace", readOnly: true),
                .init(virtual: "/tmp", host: "/tmp")
            ],
            backing: RealFileSystem())
        let cap = CapturingShell()
        cap.shell.fileSystem = mounted
        cap.shell.registerStandardCommands()

        let status = try await cap.shell.run("mount")
        #expect(status == .success)
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.contains { $0.contains(" on /tmp type sandbox (rw)") })
    }

    @Test func collapsesRealPathAliasMount() async throws {
        // macOS sandbox: /tmp → $TMPDIR's host path, plus a self-mapping
        // alias mounting that host path under its own (host) name so a
        // literal `$TMPDIR` still resolves. `mount` must fold the alias
        // into /tmp and never print the host path.
        let hostTmp = "/var/folders/ab/cdef/T"
        let mounted = MountedFileSystem(
            mounts: [
                .init(virtual: "/", host: "/workspace", readOnly: true),
                .init(virtual: "/tmp", host: hostTmp),
                .init(virtual: hostTmp, host: hostTmp)
            ],
            backing: RealFileSystem())
        let cap = CapturingShell()
        cap.shell.fileSystem = mounted
        cap.shell.registerStandardCommands()

        let status = try await cap.shell.run("mount")
        #expect(status == .success)
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)   // /, /tmp — the alias folded in
        #expect(lines.contains { $0.contains(" on /tmp type sandbox") })
        #expect(!cap.stdout.contains("folders"))   // no host path leaks
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
