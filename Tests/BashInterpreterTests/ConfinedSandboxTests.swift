import Testing
import Foundation
@testable import BashInterpreter

/// The #83 contract at the interpreter level: one ``PathMapping``
/// drives BOTH enforcement facades — the bash-side
/// ``MountedFileSystem`` (Facade A) and the ShellKit pair
/// `Shell.resolve` + `Sandbox.confined(to:)` that FileManager-backed
/// callers use (Facade B). A path must be translated and confined
/// identically no matter which door it arrives through, `$TMPDIR`
/// carries the virtual `/tmp` spelling, and host paths fold back to
/// virtual on the way out.
///
/// (Gate mechanics in isolation — prefix collisions, network policy,
/// region derivation — are pinned by ShellKit's `PathMappingTests`;
/// this suite covers the wiring SwiftBash layers on top. It replaces
/// the `BashWorkspaceSandboxTests` suite that pinned the retired
/// `Sandbox.bashWorkspace` carve-out gate.)
@Suite(.timeLimit(.minutes(1))) struct ConfinedSandboxTests {

    /// Workspace + per-instance temp dir on real disk, the mapping
    /// over them, and a bash `Shell` wired the way `swift-bash exec
    /// --sandbox` does it. Caller removes both dirs.
    private struct Fixture {
        let workspace: URL
        let temp: URL
        let mapping: PathMapping
        let shell: Shell

        func cleanup() {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private static func makeFixture() throws -> Fixture {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(),
                       isDirectory: true)
        let workspace = base.appendingPathComponent(
            "confined-ws-\(UUID().uuidString)", isDirectory: true)
        let temp = base.appendingPathComponent(
            "swiftbash-confined-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: temp, withIntermediateDirectories: true)
        let mapping = PathMapping(mounts: [
            .init(virtual: "/batch", host: workspace.path),
            .init(virtual: "/tmp", host: temp.path)
        ])
        var env = Environment()
        env.workingDirectory = "/batch"
        env.variables["HOME"] = "/batch"
        env.variables["TMPDIR"] = "/tmp"
        let shell = Shell(
            fileSystem: MountedFileSystem(mapping: mapping,
                                          backing: RealFileSystem()),
            environment: env)
        shell.sandbox = .confined(to: mapping,
                                  home: "/batch",
                                  temporaryDirectory: temp)
        return Fixture(workspace: workspace, temp: temp,
                       mapping: mapping, shell: shell)
    }

    // MARK: - Two doors, same files

    @Test func bashWritesAreReadableThroughResolve() async throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        // Facade A: a bash builtin writes through the mount table.
        try await fixture.shell.fileSystem.createDirectory(
            "/tmp/probe", intermediates: true)
        try await fixture.shell.fileSystem.writeData(
            Data("scratch\n".utf8), to: "/tmp/probe/data.txt",
            append: false)

        // Facade B: the same virtual spelling, resolved + authorized
        // + read with Foundation — the fd/rg/jq path (#48 / #55 / #83).
        let resolved = fixture.shell.resolve("/tmp/probe/data.txt")
        #expect(resolved.path == fixture.temp.path + "/probe/data.txt")
        try await fixture.shell.sandbox?.authorize(resolved)
        #expect(String(bytes: try Data(contentsOf: resolved),
                       encoding: .utf8) == "scratch\n")
    }

    @Test func foundationWritesAreReadableThroughBash() async throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        // Facade B writes (a SwiftPorts CLI creating workspace
        // output)…
        let resolved = fixture.shell.resolve("/batch/report.txt")
        #expect(resolved.path == fixture.workspace.path + "/report.txt")
        try await fixture.shell.sandbox?.authorize(resolved)
        try Data("report\n".utf8).write(to: resolved)

        // …and Facade A reads the identical file back via the
        // virtual spelling.
        let bytes = try await fixture.shell.fileSystem.readData(
            "/batch/report.txt")
        #expect(String(bytes: bytes, encoding: .utf8) == "report\n")
    }

    @Test func tmpdirEnvSpellingTranslatesForFacadeB() async throws {
        // `$TMPDIR` is the virtual `/tmp` now (#82 → #83): scripts
        // pass it to FileManager-backed CLIs, which translate it
        // through the bound shell rather than doing raw I/O on the
        // literal spelling.
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let tmpdir = fixture.shell.environment.variables["TMPDIR"]
        #expect(tmpdir == "/tmp")

        try await fixture.shell.withCurrent {
            let resolved = ShellKit.Shell.resolve(tmpdir! + "/via-env.txt")
            #expect(resolved.path == fixture.temp.path + "/via-env.txt")
            // Relative paths resolve against the virtual CWD and
            // translate to the workspace host dir.
            #expect(ShellKit.Shell.resolve("rel.txt").path
                    == fixture.workspace.path + "/rel.txt")
            // The I/O-facing CWD is the workspace's host dir; the
            // script-visible one stays virtual.
            #expect(ShellKit.Shell.currentDirectory.path
                    == fixture.workspace.path)
            #expect(ShellKit.Shell.current.environment.workingDirectory
                    == "/batch")
        }
    }

    @Test func mktempAnswerRoundTripsThroughResolve() async throws {
        // `jq "$(mktemp)"`: mktemp hands the script a VIRTUAL path;
        // the consuming CLI must land on the same host file bash
        // created.
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        let virtualPath = try await fixture.shell.fileSystem
            .makeTempPath(prefix: "roundtrip")
        #expect(virtualPath.hasPrefix("/tmp/"))
        try await fixture.shell.fileSystem.writeData(
            Data("tmpfile\n".utf8), to: virtualPath, append: false)

        let resolved = fixture.shell.resolve(virtualPath)
        #expect(resolved.path.hasPrefix(fixture.temp.path + "/"))
        try await fixture.shell.sandbox?.authorize(resolved)
        #expect(String(bytes: try Data(contentsOf: resolved),
                       encoding: .utf8) == "tmpfile\n")
    }

    // MARK: - Outbound: host paths fold back to virtual

    @Test func displayPathFoldsHostPathsBackToVirtual() async throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        // resolve → displayPath is the identity on virtual spellings
        // (`realpath` hygiene for Facade B output like fd's
        // --absolute-path).
        let resolved = fixture.shell.resolve("/tmp/show/me.txt")
        #expect(fixture.shell.displayPath(for: resolved)
                == "/tmp/show/me.txt")
        #expect(fixture.shell.displayPath(
            for: fixture.workspace.path + "/out.txt")
            == "/batch/out.txt")
        // The sandbox's host-spelled temp region folds to `/tmp` —
        // what `os.tmpdir()`-style consumers report.
        let tempRegion = fixture.shell.sandbox!.temporaryDirectory
        #expect(fixture.shell.displayPath(for: tempRegion) == "/tmp")
        // Paths outside every mount display as given.
        #expect(fixture.shell.displayPath(for: "/etc/passwd")
                == "/etc/passwd")
    }

    // MARK: - Same boundary at both doors

    @Test func gateDeniesVirtualSpellingsAndOutsidePaths() async throws {
        // The gate authorizes HOST space only — `Shell.resolve` output.
        // A literal virtual spelling reaching it (a caller that
        // skipped translation) would mean raw I/O on the host's
        // shared `/tmp` / nonexistent `/batch`, so it must deny.
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let sandbox = fixture.shell.sandbox!

        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: "/tmp/leak"))
        }
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: "/batch/f"))
        }
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(URL(fileURLWithPath: "/etc/passwd"))
        }
        // Sibling instances stay isolated (#82): another sandbox's
        // temp dir — same platform root — never authorizes.
        let sibling = try Self.makeFixture()
        defer { sibling.cleanup() }
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                sibling.temp.appendingPathComponent("other.txt"))
        }
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await sandbox.authorize(
                URL(fileURLWithPath: NSTemporaryDirectory(),
                    isDirectory: true))
        }
    }

    @Test func hostSpellingsAreUnaddressableAtBothDoors() async throws {
        // Namespace discipline (Codex review on ShellKit#17): a
        // script holding the HOST path of a mounted dir must not be
        // able to address files through it. Facade A already ENOENTs
        // it (no mount matches); Facade B's resolve voids it so the
        // gate denies — the two doors agree.
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        try await fixture.shell.fileSystem.writeData(
            Data("secret\n".utf8), to: "/batch/secret.txt", append: false)
        let hostSpelling = fixture.workspace.path + "/secret.txt"

        // Facade A: not part of the virtual namespace.
        #expect(try await fixture.shell.fileSystem
            .metadata(hostSpelling) == nil)

        // Facade B: voided by resolve, denied by the gate, and the
        // voided location cannot exist on disk.
        let resolved = fixture.shell.resolve(hostSpelling)
        #expect(!FileManager.default.fileExists(atPath: resolved.path))
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await fixture.shell.sandbox!.authorize(resolved)
        }
    }

#if !os(Windows)
    @Test func symlinkEscapeIsRejectedAtBothDoors() async throws {
        // A symlink planted inside the temp dir pointing outside the
        // sandbox: Facade A reads it back as ENOENT (canonical gate),
        // and Facade B's authorize denies the resolved host path —
        // identical confinement, one boundary (#55 / #82 / #83).
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let linkHost = fixture.temp.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(
            atPath: linkHost.path, withDestinationPath: "/")

        // Facade A: the virtual spelling reports not-found.
        #expect(try await fixture.shell.fileSystem
            .metadata("/tmp/escape-link") == nil)
        await #expect(throws: FileSystemError.self) {
            _ = try await fixture.shell.fileSystem
                .readData("/tmp/escape-link")
        }

        // Facade B: the translated host path is denied by the gate.
        let resolved = fixture.shell.resolve("/tmp/escape-link")
        #expect(resolved.path == linkHost.path)
        await #expect(throws: ShellKit.Sandbox.Denial.self) {
            try await fixture.shell.sandbox!.authorize(resolved)
        }
    }
#endif
}
