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
                .init(virtual: "/", host: sandbox.path),
                .init(virtual: "/tmp", host: tmp.path)
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

    @Test("`ls /` surfaces a cross-store mount point (`/tmp`)")
    func lsRootShowsTmpMount() async throws {
        let bench = try makeBench()
        defer {
            try? FileManager.default.removeItem(at: bench.sandboxRoot)
            try? FileManager.default.removeItem(at: bench.tmpRoot)
        }

        // `/tmp` is mounted to a host dir OUTSIDE the sandbox root, so it
        // never appears in the root's on-disk listing. It should still
        // show up as a child of `/` by virtue of the mount table.
        let entries = try await bench.cap.shell.fileSystem.list("/")
            .map(\.name)
        #expect(entries.contains("tmp"))
        let tmp = try #require(try await bench.cap.shell.fileSystem
            .list("/").first { $0.name == "tmp" })
        #expect(tmp.metadata.kind == .directory)

        // And it's traversable / listable, not just a name.
        let status = try await bench.cap.shell.run(
            "echo hi > /tmp/probe.txt; ls /tmp")
        #expect(status == .success)
        #expect(bench.cap.stdout.split(separator: "\n").map(String.init)
            .contains("probe.txt"))
    }

    @Test("a mount whose host lives on disk isn't double-listed")
    func mountNotDoubledWhenOnDisk() async throws {
        // Mirror iBash's layout: `/home` is a mount pointing at
        // `<root>/home`, which also physically exists on disk. The
        // mount-point folding must dedupe it so `ls /` shows `home`
        // exactly once (it's both a real backing entry AND a child
        // mount).
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-mount-\(UUID().uuidString)")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-mount-tmp-\(UUID().uuidString)")
        let home = sandbox.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: tmp)
        }

        let mounted = MountedFileSystem(
            mounts: [
                .init(virtual: "/", host: sandbox.path),
                .init(virtual: "/home", host: home.path),
                .init(virtual: "/tmp", host: tmp.path)
            ],
            backing: RealFileSystem())
        let names = try await mounted.list("/").map(\.name)
        #expect(names.filter { $0 == "home" }.count == 1)
        #expect(names.contains("tmp"))
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

    @Test("`..` crossing an autofs-shaped virtual name resolves lexically")
    func dotDotAcrossAutofsName() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibash-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try "hi".write(
            to: sandbox.appendingPathComponent("marker.txt"),
            atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent("home"),
            withIntermediateDirectories: true)

        // Call MountedFileSystem.list directly with a virtual path that
        // still contains `..`. This mirrors what tab-completion code in
        // an embedder does — it builds a `virtualDir = "/home/.."`
        // string and asks the FS to enumerate it, bypassing the shell's
        // `resolvePath` (which would have normalised lexically first).
        //
        // On macOS, the host's real `/home` is an autofs symlink to
        // `/System/Volumes/Data/home`. With `NSString.standardizingPath`
        // (which consults the host filesystem), `/home/..` standardises
        // to `/System/Volumes/Data`, misses the mount table, and the
        // list returns nothing — every read/list/completion through
        // that path silently fails. The fix uses `Shell.normalizePath`
        // for purely lexical normalisation, so `/home/..` stays `/`.
        let mounted = MountedFileSystem(
            mounts: [.init(virtual: "/", host: sandbox.path)],
            backing: RealFileSystem())
        let entries = try await mounted.list("/home/..")
            .map(\.name).sorted()
        #expect(entries.contains("marker.txt"))
        #expect(entries.contains("home"))
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

    @Test("symlink under mount pointing outside is rejected (no escape)")
    func symlinkEscapeRejected() async throws {
        let bench = try makeBench()
        defer {
            try? FileManager.default.removeItem(at: bench.sandboxRoot)
            try? FileManager.default.removeItem(at: bench.tmpRoot)
        }

        // Plant a symlink under the sandbox that points to /etc on the
        // host filesystem. A naive lexical confinement check would
        // accept reads through it because the symlink path itself
        // lives under the sandbox; canonicalisation has to catch it.
        let escape = bench.sandboxRoot.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: escape,
            withDestinationURL: URL(fileURLWithPath: "/etc"))

        // `cat /escape/passwd` should report ENOENT, not the contents
        // of /etc/passwd.
        let status = try await bench.cap.shell.run("cat /escape/passwd")
        #expect(!status.isSuccess)
        #expect(!bench.cap.stdout.contains("root:"))
        #expect(bench.cap.stderr.contains("/escape/passwd"))
    }

    @Test("symlink target is stored verbatim, not remapped")
    func symlinkTargetVerbatim() async throws {
        let bench = try makeBench()
        defer {
            try? FileManager.default.removeItem(at: bench.sandboxRoot)
            try? FileManager.default.removeItem(at: bench.tmpRoot)
        }

        // `ln -s foo bar` from inside the mount should land on disk
        // as a symlink with target literally `foo` (not the host
        // path of foo). Verify by reading the link's destination via
        // FileManager.
        try "hi".write(to: bench.sandboxRoot.appendingPathComponent("foo"),
                       atomically: true, encoding: .utf8)
        let status = try await bench.cap.shell.run("cd /; ln -s foo bar")
        #expect(status == .success)

        let bar = bench.sandboxRoot.appendingPathComponent("bar")
        let dest = try FileManager.default
            .destinationOfSymbolicLink(atPath: bar.path)
        #expect(dest == "foo")
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
                .init(virtual: "/", host: sandbox.path),
                .init(virtual: "/examples", host: examples.path,
                      readOnly: true)
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
        #expect(String(bytes: stillX, encoding: .utf8) == "x")
    }
}
