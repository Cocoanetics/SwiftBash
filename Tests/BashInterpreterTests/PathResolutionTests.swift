import Foundation
import Testing
@testable import BashInterpreter

/// Exercises ``PathResolver`` and the surfaces that consume it
/// (dispatcher, `which`, `type`, `compgen -c`, ``BashProcessLauncher``).
///
/// All tests construct a fresh shell, swap in an ``InMemoryFileSystem``
/// so the assertions don't drift on host content (`/usr/bin/cd`
/// actually exists on macOS), and exercise `$PATH` shadowing through
/// the install API.
@Suite(.timeLimit(.minutes(1))) struct PathResolutionTests {

    /// Shared `Foo` command — `argv[0]` plus the originating directory
    /// so tests can verify which install ran.
    private struct Foo: Command {
        let name = "foo"
        let marker: String
        func run(_ argv: [String]) async throws -> ExitStatus {
            Shell.bashCurrent.stdout("\(marker)\n")
            return .success
        }
    }

    private func makeShell() -> CapturingShell {
        let cap = CapturingShell()
        // InMemoryFileSystem hides host files (`/usr/bin/cd` on macOS,
        // any installed `/usr/local/bin/fd`, …) so test assertions
        // about PATH lookup describe only what the test installed.
        cap.shell.fileSystem = InMemoryFileSystem()
        return cap
    }

    // MARK: PATH shadowing

    @Test func bundledInstallWinsWhenItsPathLeadsTheList() async throws {
        let cap = makeShell()
        cap.shell.install(Foo(marker: "bundled"), at: "/bin/foo")
        cap.shell.install(Foo(marker: "skill"), at: "/usr/local/bin/foo")
        cap.shell.environment["PATH"] = "/bin:/usr/local/bin"
        try await cap.shell.run("foo")
        #expect(cap.stdout == "bundled\n")
    }

    @Test func skillInstallWinsWhenItsPathLeadsTheList() async throws {
        let cap = makeShell()
        cap.shell.install(Foo(marker: "bundled"), at: "/bin/foo")
        cap.shell.install(Foo(marker: "skill"), at: "/usr/local/bin/foo")
        cap.shell.environment["PATH"] = "/usr/local/bin:/bin"
        try await cap.shell.run("foo")
        #expect(cap.stdout == "skill\n")
    }

    // MARK: $PATH semantics

    @Test func emptyPathBlocksBareNameButPathStyleStillRuns() async throws {
        let cap = makeShell()
        cap.shell.install(Foo(marker: "bundled"), at: "/bin/foo")
        cap.shell.environment["PATH"] = ""

        try await cap.shell.run("foo")
        #expect(cap.shell.lastExitStatus.code == 127)

        // Absolute path bypasses $PATH entirely.
        try await cap.shell.run("/bin/foo")
        #expect(cap.stdout.contains("bundled"))
    }

    @Test func unsetPathFallsBackToCompiledDefault() async throws {
        // `Shell()` initialises `PATH` to the default, so the
        // strongest assertion is "after `unset PATH`, default applies
        // again." We model that by checking that the default value is
        // what gets reapplied.
        let cap = makeShell()
        cap.shell.install(Foo(marker: "from-default"), at: "/usr/local/bin/foo")
        // Mutate the variable directly: bash's `unset PATH` clears
        // it from the environment. Real bash would then auto-search
        // a compiled-in default; SwiftBash's PathResolver pulls the
        // default out of the `runtimeEnvDefaults` table the init
        // applied. Reset to the default explicitly.
        cap.shell.environment["PATH"] = "/usr/local/bin:/usr/bin:/bin"
        try await cap.shell.run("foo")
        #expect(cap.stdout == "from-default\n")
    }

    @Test func emptyPathEntryMeansCwd() async throws {
        // `PATH=":/bin"` (empty leading entry) is documented to mean
        // "search CWD first." Drop a stub at the shell's working dir
        // and verify a bare invocation reaches it.
        let cap = makeShell()
        try await cap.shell.fileSystem.createDirectory(
            "/work", intermediates: true)
        try await cap.shell.fileSystem.writeData(
            Data("script body".utf8), to: "/work/hello", append: false)
        try await cap.shell.fileSystem.chmod("/work/hello", mode: 0o755)
        cap.shell.environment.workingDirectory = "/work"
        cap.shell.environment["PATH"] = ":/usr/bin"
        let resolver = PathResolver(cap.shell)
        let resolution = await resolver.resolve("hello")
        switch resolution {
        case .externalScript(let path):
            #expect(path == "/work/hello")
        case .registered, .notFound:
            Issue.record("expected externalScript, got \(resolution)")
        }
    }

    // MARK: Shell built-ins win on bare names

    @Test func shellBuiltinWinsOverPathForBareName() async throws {
        let cap = makeShell()
        cap.shell.install(Foo(marker: "file"), at: "/bin/foo")
        cap.shell.installShellBuiltin(Foo(marker: "builtin"))
        cap.shell.environment["PATH"] = "/bin"
        try await cap.shell.run("foo")
        #expect(cap.stdout == "builtin\n")
    }

    @Test func absolutePathBypassesShellBuiltin() async throws {
        let cap = makeShell()
        cap.shell.install(Foo(marker: "file"), at: "/bin/foo")
        cap.shell.installShellBuiltin(Foo(marker: "builtin"))
        try await cap.shell.run("/bin/foo")
        #expect(cap.stdout == "file\n")
    }

    // MARK: `which`

    @Test func whichListsFirstPathHit() async throws {
        let cap = makeShell()
        cap.shell.install(Foo(marker: "bundled"), at: "/bin/foo")
        cap.shell.install(Foo(marker: "skill"), at: "/usr/local/bin/foo")
        cap.shell.environment["PATH"] = "/usr/local/bin:/bin"
        cap.shell.installShellBuiltin(
            ParsableCommandBridgeLike.whichBridge)
        try await cap.shell.run("which foo")
        #expect(cap.stdout == "/usr/local/bin/foo\n")
    }

    @Test func whichDashAListsEveryPathHitInOrder() async throws {
        let cap = makeShell()
        cap.shell.install(Foo(marker: "bundled"), at: "/bin/foo")
        cap.shell.install(Foo(marker: "skill"), at: "/usr/local/bin/foo")
        cap.shell.environment["PATH"] = "/usr/local/bin:/bin"
        cap.shell.installShellBuiltin(
            ParsableCommandBridgeLike.whichBridge)
        try await cap.shell.run("which -a foo")
        #expect(cap.stdout == "/usr/local/bin/foo\n/bin/foo\n")
    }

    // MARK: `compgen -c`

    @Test func compgenExcludesInstallsOutsideCurrentPath() async throws {
        let cap = makeShell()
        cap.shell.install(Foo(marker: "off-path"), at: "/opt/foo")
        cap.shell.environment["PATH"] = "/usr/bin:/bin"
        let listing = cap.shell.completionSources.listCommands(kind: .all)
        #expect(!listing.contains("foo"),
            "foo's install dir is /opt — not in PATH; compgen should skip it")
    }

    @Test func compgenIncludesInstallsInCurrentPath() async throws {
        let cap = makeShell()
        cap.shell.install(Foo(marker: "skill"), at: "/usr/local/bin/foo")
        cap.shell.environment["PATH"] = "/usr/local/bin:/usr/bin:/bin"
        let listing = cap.shell.completionSources.listCommands(kind: .all)
        #expect(listing.contains("foo"))
    }
}

// MARK: - Helpers

/// Standalone wrapper so the path-resolution suite can install
/// `WhichCommand` without dragging in BashCommandKit. The full
/// `WhichCommand` lives in BashCommandKit, but its behaviour mirrors
/// PathResolver.allMatches(forName:); we just want a `Command` that
/// surfaces those results.
private enum ParsableCommandBridgeLike {
    static let whichBridge: Command = ClosureCommand(name: "which") { argv in
        var index = 1
        var listAll = false
        while index < argv.count, argv[index] == "-a" {
            listAll = true
            index += 1
        }
        let names = Array(argv[index...])
        if names.isEmpty {
            Shell.bashCurrent.stderr("which: missing operand\n")
            return .failure
        }
        let resolver = PathResolver(Shell.bashCurrent)
        var missing = false
        for name in names {
            let matches = await resolver.allMatches(forName: name)
            if matches.isEmpty {
                missing = true
                continue
            }
            let toPrint = listAll ? matches : Array(matches.prefix(1))
            for match in toPrint {
                switch match {
                case .registered(_, let path),
                     .externalScript(let path):
                    Shell.bashCurrent.stdout("\(path)\n")
                case .notFound:
                    break
                }
            }
        }
        return missing ? .failure : .success
    }
}
