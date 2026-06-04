import Testing
import Foundation
import ShellKit
@testable import BashInterpreter
@testable import BashSwiftScript

/// End-to-end tests for the SwiftBash ↔ SwiftScript integration.
/// Each test constructs a SwiftBash `Shell`, registers SwiftScript
/// via `registerSwiftScript()`, drops a script onto disk, and runs
/// it through the bash dispatcher (`shell.run("./path/to/script")`)
/// — the same path the standalone CLI takes for an executable
/// script with a `#!`-shebang.

@Suite(.timeLimit(.minutes(1))) struct BashSwiftScriptTests {

    /// Build a SwiftBash `Shell` with capturing sinks and SwiftScript
    /// registered. Returns the shell + a capture handle for assertions.
    private func makeShell(
        sandbox: ShellKit.Sandbox? = nil,
        networkConfig: NetworkConfig? = nil,
        hostInfo: HostInfo = .synthetic,
        stdin: InputSource = .empty
    ) -> (shell: BashInterpreter.Shell, capture: TestCapture) {
        let capture = TestCapture()
        let shell = BashInterpreter.Shell(
            stdin: stdin,
            stdout: capture.stdoutSink,
            stderr: capture.stderrSink,
            environment: Environment(),
            sandbox: sandbox,
            networkConfig: networkConfig,
            hostInfo: hostInfo)
        // Primary init leaves the registry empty; install the bash
        // defaults so test scripts using `echo` / `set` / `exit`
        // behave like a real shell.
        shell.installDefaultBuiltins()
        shell.registerSwiftScript()
        return (shell, capture)
    }

    /// Drop a script onto disk with the execute bit set and clean
    /// up after the test. Matches bash semantics: the dispatcher
    /// refuses regular files without `chmod +x`.
    private func writeScript(
        _ source: String,
        suffix: String = ".swift"
    ) throws -> (path: String, dir: String) {
        let dir = NSTemporaryDirectory()
            + "swift-bash-swift-script-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/script\(suffix)"
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path)
        return (path, dir)
    }

    /// POSIX-single-quote a path so it survives bash'shell word
    /// expansion intact. Critical on Windows where
    /// `NSTemporaryDirectory()` returns `\`-separated paths and
    /// unquoted `\X` is a bash escape — without quoting the path
    /// reaches the dispatcher with every backslash already eaten.
    private static func bashQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: smoke

    @Test func runsHelloWorldFromShebang() async throws {
        let (shell, cap) = makeShell()
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            print("hello swiftscript")
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        let status = try await shell.run(Self.bashQuote(script.path))
        #expect(status.code == 0)
        #expect(cap.stdout == "hello swiftscript\n")
    }

    @Test func bareSwiftShebangAlsoRoutesToSwiftScript() async throws {
        let (shell, cap) = makeShell()
        let script = try writeScript("""
            #!/usr/bin/env swift
            print(40 + 2)
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        let status = try await shell.run(Self.bashQuote(script.path))
        #expect(status.code == 0)
        #expect(cap.stdout == "42\n")
    }

    // MARK: argv plumbing

    @Test func commandLineArgumentsReflectScriptArgs() async throws {
        let (shell, cap) = makeShell()
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            for a in CommandLine.arguments {
                print(a)
            }
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        try await shell.run("\(Self.bashQuote(script.path)) one two three")
        let lines = cap.stdout.split(separator: "\n").map(String.init)
        // The dispatcher passes the *resolved* path through
        // `CommandLine.arguments[0]` — on Windows that'shell the
        // forward-slash drive-letter form, on Unix it'shell identity.
        #expect(lines == [shell.resolvePath(script.path), "one", "two", "three"])
    }

    // MARK: exit code

    @Test func scriptExitPropagatesAsBashExitStatus() async throws {
        // Direct dispatch: exit(7) inside the script returns
        // ExitStatus(7) to the bash dispatcher.
        let (shell, cap) = makeShell()
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            print("before")
            exit(7)
            print("never")
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        let status = try await shell.run(Self.bashQuote(script.path))
        #expect(status.code == 7)
        #expect(cap.stdout == "before\n")
    }

    @Test func swiftScriptExitVisibleViaBashDollarQuestion() async throws {
        // The dispatcher updates `lastExitStatus`; a follow-on
        // command in the same list reads it via `$?`.
        let (shell, cap) = makeShell()
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            exit(3)
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        try await shell.run("\(Self.bashQuote(script.path)); echo $?")
        #expect(cap.stdout == "3\n")
    }

    // MARK: diagnostics

    @Test func parseErrorReportsExitOneOnStderr() async throws {
        let (shell, cap) = makeShell()
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            let x = ###
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        let status = try await shell.run(Self.bashQuote(script.path))
        #expect(status.code == 1)
        #expect(cap.stderr.contains("error:"))
    }

    @Test func diagnosticLineNumbersMatchOriginalFile() async throws {
        // Shebang strip preserves a leading newline so SwiftScript
        // diagnostics line up with the original file (`swift` itself
        // counts the shebang as line 1, body starts at line 2).
        let (shell, cap) = makeShell()
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            let x = 1
            let y = ###
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        _ = try await shell.run(Self.bashQuote(script.path))
        let captured = cap.stderr
        let mentions3 = captured.contains(":3:") || captured.contains("3 |")
        #expect(mentions3, "expected line-3 reference in stderr")
    }

    // MARK: subshell isolation

    @Test func parentPositionalsArePreservedAfterDispatch() async throws {
        let (shell, _) = makeShell()
        shell.scriptName = "outer"
        shell.positionalParameters = ["outerArg"]
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            print("inside")
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        try await shell.run("\(Self.bashQuote(script.path)) inner")
        #expect(shell.scriptName == "outer")
        #expect(shell.positionalParameters == ["outerArg"])
    }

    // MARK: stdin via pipeline

    @Test func bashPipelineFeedsStdinIntoSwiftScript() async throws {
        // `echo hello | ./script.swift` — the stage stdin from
        // bash'shell pipeline becomes SwiftScript'shell `Shell.current.stdin`,
        // which is what `readLine()` consumes.
        let (shell, cap) = makeShell()
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            if let line = readLine() {
                print("got: \\(line)")
            }
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        try await shell.run("echo hello | \(Self.bashQuote(script.path))")
        #expect(cap.stdout == "got: hello\n")
    }

    // MARK: sandbox

    @Test func sandboxedShellDeniesScriptDiskAccess() async throws {
        // SwiftScript bridges call `authorizePath` before disk
        // touches; with a SwiftBash sandbox bound, off-root paths
        // throw into the script'shell `do/catch`.
        let root = NSTemporaryDirectory()
            + "swift-bash-script-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (shell, cap) = makeShell(
            sandbox: ShellKit.Sandbox.rooted(
                at: URL(fileURLWithPath: root),
                allowedHosts: []))
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            import Foundation
            do {
                _ = try String(contentsOfFile: "/etc/passwd", encoding: .utf8)
                print("LEAKED")
            } catch {
                print("denied")
            }
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        try await shell.run(Self.bashQuote(script.path))
        #expect(cap.stdout == "denied\n")
    }

    // MARK: subprocess routing

    @Test func subprocessRunRoutesThroughBashCommandRegistry() async throws {
        // The full polyglot story end-to-end: a SwiftScript script
        // running under SwiftBash uses `import Subprocess` to call a
        // command name that **only exists in the bash registry, not
        // on the host PATH**. Because the SwiftBash `Shell`'shell default
        // `processLauncher` is `BashProcessLauncher` (not the
        // `DefaultProcessLauncher` that ShellKit installs), the call
        // resolves to the registered closure. A regression that
        // routed through real exec would fail with "executable not
        // found" because no such binary exists anywhere — that'shell what
        // makes this test load-bearing on the routing claim, vs. a
        // generic `echo` test where bash-builtin and host `/bin/echo`
        // produce identical bytes.
        let (shell, cap) = makeShell()
        // Sentinel registered only in this Shell'shell command table.
        // Prints a marker that no real binary anywhere would emit.
        shell.installShellBuiltin(name: "swiftbash-only-marker") { argv in
            let payload = argv.dropFirst().joined(separator: " ")
            Shell.bashCurrent.stdout("REGISTRY-OK: \(payload)\n")
            return .success
        }
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            import Subprocess
            let r = try await Subprocess.run(
                Executable.name("swiftbash-only-marker"),
                arguments: ["hello-from-bash-builtin"],
                output: Output.string(limit: 4096))
            if let out = r.standardOutput, r.terminationStatus.isSuccess {
                print("got=\\(out)", terminator: "")
            } else {
                print("bridge dispatch failed")
            }
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        let status = try await shell.run(Self.bashQuote(script.path))
        #expect(status.code == 0)
        // The sentinel prefix proves the call landed on the registered
        // closure, not on a host binary that happens to share the name.
        #expect(cap.stdout == "got=REGISTRY-OK: hello-from-bash-builtin\n")
    }

    @Test func subprocessRunWithCanonicalPathHitsBashBuiltin() async throws {
        // `Executable.path("/bin/echo")` is resolved by
        // `BashProcessLauncher` against `BinCatalog.knownPaths` — the
        // canonical path matches, so it dispatches to the registered
        // `echo` builtin (not the host'shell `/bin/echo`). Mirrors the
        // `BinCatalogOverlay` synthesized-file rule from the bash
        // side.
        //
        // To make the routing visible (host `/bin/echo` produces
        // identical output for the same argv), override the registry'shell
        // `echo` with a sentinel-prepending closure. A regression that
        // bypassed `BashProcessLauncher` for canonical-path resolution
        // would invoke the real `/bin/echo` and miss the prefix.
        let (shell, cap) = makeShell()
        // The test invokes `/bin/echo` (absolute path), so the built-in
        // form would be bypassed. Override the file-backed form at
        // `/bin/echo` directly so the sentinel is what dispatch hits.
        shell.install(ClosureCommand(name: "echo") { argv in
            let payload = argv.dropFirst().joined(separator: " ")
            Shell.bashCurrent.stdout("BUILTIN: \(payload)\n")
            return .success
        })
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            import Subprocess
            let r = try await Subprocess.run(
                Executable.path("/bin/echo"),
                arguments: ["via-canonical-path"],
                output: Output.string(limit: 4096))
            print(r.standardOutput ?? "<none>", terminator: "")
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        try await shell.run(Self.bashQuote(script.path))
        #expect(cap.stdout == "BUILTIN: via-canonical-path\n")
    }

    // MARK: identity

    @Test func swiftScriptSeesSandboxIdentity() async throws {
        var info = HostInfo.synthetic
        info.userName = "agent"
        info.hostName = "sandbox.local"
        let (shell, cap) = makeShell(hostInfo: info)
        let script = try writeScript("""
            #!/usr/bin/env swift-script
            import Foundation
            print(ProcessInfo.processInfo.userName)
            print(ProcessInfo.processInfo.hostName)
            """)
        defer { try? FileManager.default.removeItem(atPath: script.dir) }

        try await shell.run(Self.bashQuote(script.path))
        #expect(cap.stdout == "agent\nsandbox.local\n")
    }
}

// MARK: - Test capture helper

/// Wires `OutputSink`shell into `StringBox`es so tests can read what the
/// script emitted. Same shape as `CapturingShell` in the
/// BashInterpreterTests suite, copied here because test-target
/// helpers don't share across SwiftPM packages.
final class TestCapture: @unchecked Sendable {

    let stdoutSink: OutputSink
    let stderrSink: OutputSink

    private final class StringBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ data: Data) {
            // Test stub: stdout bytes are arbitrary; tolerate non-UTF-8.
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: data, as: UTF8.self)
            lock.lock(); defer { lock.unlock() }
            value.append(text)
        }
        func read() -> String {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    private let _stdout = StringBox()
    private let _stderr = StringBox()

    var stdout: String { _stdout.read() }
    var stderr: String { _stderr.read() }

    init() {
        let stdout = _stdout
        let stderr = _stderr
        self.stdoutSink = OutputSink(onWrite: { stdout.append($0) })
        self.stderrSink = OutputSink(onWrite: { stderr.append($0) })
    }
}
