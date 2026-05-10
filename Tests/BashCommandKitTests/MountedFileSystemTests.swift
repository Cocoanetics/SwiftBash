import Testing
import Foundation
@testable import BashInterpreter
@testable import BashCommandKit

@Suite("MountedFileSystem path mapping")
struct MountedFileSystemTests {

    /// Build a sandbox dir + tmp dir + a shell wired to a 2-mount FS.
    private struct Bench {
        let sandboxRoot: URL
        let tmpRoot: URL
        let cap: CapturingShell
    }

    private func makeBench() throws -> Bench {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-mount-\(UUID().uuidString)")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-mount-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp,
                                                withIntermediateDirectories: true)

        let real = RealFileSystem()
        let mounted = MountedFileSystem(
            mounts: [
                .init(virtual: "/",    host: sandbox.path),
                .init(virtual: "/tmp", host: tmp.path),
            ],
            backing: real)

        let cap = CapturingShell()
        cap.shell.fileSystem = mounted
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = "/"
        return Bench(sandboxRoot: sandbox, tmpRoot: tmp, cap: cap)
    }

    @Test("`ls /` lists the sandbox root, not the host root")
    func lsRootMapsToSandbox() async throws {
        let bench = try makeBench()
        defer {
            try? FileManager.default.removeItem(at: bench.sandboxRoot)
            try? FileManager.default.removeItem(at: bench.tmpRoot)
        }

        try "hi".write(to: bench.sandboxRoot.appendingPathComponent("hello.txt"),
                       atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: bench.sandboxRoot.appendingPathComponent("home"),
            withIntermediateDirectories: true)

        let status = try await bench.cap.shell.run("ls /")
        #expect(status == .success)
        let lines = bench.cap.stdout.split(separator: "\n").map(String.init).sorted()
        #expect(lines.contains("hello.txt"))
        #expect(lines.contains("home"))
    }

    @Test("`/tmp/foo` writes go to the tmp mount, not the root")
    func tmpMountIsSeparate() async throws {
        let bench = try makeBench()
        defer {
            try? FileManager.default.removeItem(at: bench.sandboxRoot)
            try? FileManager.default.removeItem(at: bench.tmpRoot)
        }

        let status = try await bench.cap.shell.run("echo wrote > /tmp/scratch.txt")
        #expect(status == .success)

        // Lands in the tmp mount's host directory.
        let tmpFile = bench.tmpRoot.appendingPathComponent("scratch.txt")
        #expect(FileManager.default.fileExists(atPath: tmpFile.path))

        // Does NOT leak into the sandbox root.
        let leaked = bench.sandboxRoot.appendingPathComponent("tmp/scratch.txt")
        #expect(!FileManager.default.fileExists(atPath: leaked.path))
    }

    @Test("paths outside any mount look like ENOENT")
    func unmountedIsMissing() async throws {
        let bench = try makeBench()
        defer {
            try? FileManager.default.removeItem(at: bench.sandboxRoot)
            try? FileManager.default.removeItem(at: bench.tmpRoot)
        }

        let status = try await bench.cap.shell.run("cat /etc/passwd")
        #expect(!status.isSuccess)
        #expect(bench.cap.stderr.contains("/etc/passwd"))
    }

    @Test("realpath returns virtual paths, not host paths")
    func realpathStaysVirtual() async throws {
        let bench = try makeBench()
        defer {
            try? FileManager.default.removeItem(at: bench.sandboxRoot)
            try? FileManager.default.removeItem(at: bench.tmpRoot)
        }

        try "x".write(to: bench.sandboxRoot.appendingPathComponent("x.txt"),
                      atomically: true, encoding: .utf8)
        let status = try await bench.cap.shell.run("realpath /x.txt")
        #expect(status == .success)
        #expect(bench.cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "/x.txt")
        // Specifically, the host path must NOT leak.
        #expect(!bench.cap.stdout.contains(bench.sandboxRoot.path))
    }

    @Test("`cd ..` from `/` stays at `/`")
    func dotDotFromRoot() async throws {
        let bench = try makeBench()
        defer {
            try? FileManager.default.removeItem(at: bench.sandboxRoot)
            try? FileManager.default.removeItem(at: bench.tmpRoot)
        }

        // Pwd is `/` initially. `..` standardises to `/` and the
        // resolve walk lands back at the sandbox root.
        let status = try await bench.cap.shell.run("cd ..; pwd")
        #expect(status == .success)
        #expect(bench.cap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "/")
    }

    @Test("read-only mount rejects writes")
    func readOnlyMount() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let examples = sandbox.appendingPathComponent("ex")
        try FileManager.default.createDirectory(at: examples,
                                                withIntermediateDirectories: true)
        try "x".write(to: examples.appendingPathComponent("x.txt"),
                      atomically: true, encoding: .utf8)

        let mounted = MountedFileSystem(
            mounts: [
                .init(virtual: "/",         host: sandbox.path),
                .init(virtual: "/examples", host: examples.path,
                      readOnly: true),
            ],
            backing: RealFileSystem())

        let cap = CapturingShell()
        cap.shell.fileSystem = mounted
        cap.shell.registerStandardCommands()
        cap.shell.environment.workingDirectory = "/"

        let read = try await cap.shell.run("cat /examples/x.txt")
        #expect(read == .success)
        #expect(cap.stdout == "x")

        // Write redirection through `>` reaches the FS layer's
        // openWrite, which throws permissionDenied. The interpreter
        // surfaces that as either a non-zero status or a thrown
        // BashInterpreterError depending on where it lands; either
        // way, the file content is unchanged.
        _ = try? await cap.shell.run("echo y > /examples/x.txt")
        let stillX = try Data(contentsOf: examples.appendingPathComponent("x.txt"))
        #expect(String(decoding: stillX, as: UTF8.self) == "x")
    }
}
