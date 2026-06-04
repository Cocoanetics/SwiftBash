import Foundation
import Testing
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct BashProcessLauncherTests {

    // MARK: Default install

    @Test func defaultLauncherIsBashProcessLauncher() {
        let shell = Shell()
        // The SwiftBash designated init resolves a `nil`
        // `processLauncher` argument to ``BashProcessLauncher`` instead
        // of the ShellKit-default ``DefaultProcessLauncher``.
        // (Fall-through to real exec is wrong for SwiftBash's
        // sandbox-by-default model.)
        #expect(shell.processLauncher is BashProcessLauncher)
    }

    // MARK: Resolve hit

    @Test func launcherDispatchesByExecutableName() async throws {
        let shell = Shell()
        shell.installShellBuiltin(name: "greet") { argv in
            let who = argv.dropFirst().first ?? "world"
            Shell.bashCurrent.stdout("hello \(who)\n")
            return .success
        }

        let buffer = BufferingSink()
        let record = try await shell.withCurrent {
            try await shell.processLauncher.launch(
                .name("greet"),
                arguments: ["alice"],
                environment: shell.environment,
                workingDirectory: nil,
                input: .empty,
                output: buffer.sink,
                error: .discard)
        }

        #expect(record.terminationStatus.isSuccess)
        #expect(buffer.text == "hello alice\n")
    }

    @Test func launcherDispatchesCanonicalBinPath() async throws {
        // `Executable.path("/bin/echo")` should reach the shell's
        // registered `echo` — that's the canonical bin path per
        // `BinCatalog`, so it matches `BinCatalogOverlay`'s
        // synthesized-file rule on the bash side.
        let shell = Shell()
        shell.installShellBuiltin(name: "echo") { argv in
            Shell.bashCurrent.stdout(argv.dropFirst().joined(separator: " ") + "\n")
            return .success
        }

        let buffer = BufferingSink()
        let record = try await shell.withCurrent {
            try await shell.processLauncher.launch(
                .path("/bin/echo"),
                arguments: ["hi"],
                environment: shell.environment,
                workingDirectory: nil,
                input: .empty,
                output: buffer.sink,
                error: .discard)
        }

        #expect(record.terminationStatus.isSuccess)
        #expect(buffer.text == "hi\n")
    }

    @Test func launcherRefusesNonCanonicalPath() async {
        // `/tmp/echo` is NOT a canonical bin path — basename-resolving
        // it to the registered `echo` would change exact-path
        // subprocess semantics (the caller asked for a specific file
        // location, not the registry). Throws `ProcessLaunchUnresolved`
        // instead of silently dispatching.
        let shell = Shell()
        shell.installShellBuiltin(name: "echo") { _ in .success }

        await #expect(throws: ProcessLaunchUnresolved.self) {
            try await shell.withCurrent {
                _ = try await shell.processLauncher.launch(
                    .path("/tmp/echo"),
                    arguments: [],
                    environment: shell.environment,
                    workingDirectory: nil,
                    input: .empty,
                    output: .discard,
                    error: .discard)
            }
        }
    }

    // MARK: Resolve miss

    @Test func launcherThrowsUnresolvedForUnknownName() async {
        let shell = Shell()
        // SwiftBash never composes through ChainLauncher — the
        // unresolved error reaches the caller as the "command not
        // found" signal.
        await #expect(throws: ProcessLaunchUnresolved.self) {
            try await shell.withCurrent {
                _ = try await shell.processLauncher.launch(
                    .name("does-not-exist"),
                    arguments: [],
                    environment: shell.environment,
                    workingDirectory: nil,
                    input: .empty,
                    output: .discard,
                    error: .discard)
            }
        }
    }

    // MARK: Argv plumbing

    @Test func launcherPassesArgvWithNameAtIndexZero() async throws {
        let shell = Shell()
        let captured = ArgvCapture()
        shell.installShellBuiltin(name: "argecho") { argv in
            captured.set(argv)
            return .success
        }

        try await shell.withCurrent {
            _ = try await shell.processLauncher.launch(
                .name("argecho"),
                arguments: ["one", "two", "three"],
                environment: shell.environment,
                workingDirectory: nil,
                input: .empty,
                output: .discard,
                error: .discard)
        }

        #expect(captured.value == ["argecho", "one", "two", "three"])
    }

    // MARK: Exit-code mapping

    @Test func launcherReturnsExitCodeFromCommand() async throws {
        let shell = Shell()
        shell.installShellBuiltin(name: "rc") { argv in
            let code = Int32(argv.dropFirst().first.flatMap(Int.init) ?? 0)
            return ExitStatus(code)
        }

        let record = try await shell.withCurrent {
            try await shell.processLauncher.launch(
                .name("rc"),
                arguments: ["42"],
                environment: shell.environment,
                workingDirectory: nil,
                input: .empty,
                output: .discard,
                error: .discard)
        }

        guard case .exited(let code) = record.terminationStatus else {
            Issue.record("expected .exited, got \(record.terminationStatus)")
            return
        }
        #expect(code == 42)
    }

    // MARK: Stdio override / sub-shell isolation

    @Test func launcherStdoutGoesToCallerSinkNotShellSink() async throws {
        // A SwiftScript / SwiftJSCore bridge that wants to capture
        // output passes its own `OutputSink`. The parent shell's
        // stdout (where bash command output normally goes) must NOT
        // see the bytes — otherwise `$(cmd)` substitution and
        // `Subprocess.run(.string(...))` would double-print.
        let shell = Shell()
        shell.installShellBuiltin(name: "shout") { _ in
            Shell.bashCurrent.stdout("captured\n")
            return .success
        }

        let parentBuffer = BufferingSink()
        shell.stdout = parentBuffer.sink

        let bridgeBuffer = BufferingSink()
        try await shell.withCurrent {
            _ = try await shell.processLauncher.launch(
                .name("shout"),
                arguments: [],
                environment: shell.environment,
                workingDirectory: nil,
                input: .empty,
                output: bridgeBuffer.sink,
                error: .discard)
        }

        #expect(bridgeBuffer.text == "captured\n")
        #expect(parentBuffer.text == "")
    }

    // MARK: exit-code conversion

    @Test func launcherTranslatesExitToTerminationStatus() async throws {
        // A launched command that calls `exit N` (the bash builtin
        // throws an internal `ShellExit` to unwind) must surface as a
        // clean `ExecutionRecord` with `.exited(N)` — NOT as a thrown
        // error. Subprocess-style callers (a SwiftScript / SwiftJSCore
        // bridge running `Subprocess.run(.name("exit-2"))`) expect a
        // record back so they can branch on success / failure.
        let shell = Shell()
        // The default `exit` builtin is registered by `defaultCommands()`
        // — exercise it directly.

        let record = try await shell.withCurrent {
            try await shell.processLauncher.launch(
                .name("exit"),
                arguments: ["7"],
                environment: shell.environment,
                workingDirectory: nil,
                input: .empty,
                output: .discard,
                error: .discard)
        }

        guard case .exited(let code) = record.terminationStatus else {
            Issue.record("expected .exited, got \(record.terminationStatus)")
            return
        }
        #expect(code == 7)
    }

    @Test func launcherEnvironmentMutationsDontLeakToParent() async throws {
        // The launcher copies the parent shell before applying
        // overrides. A command that mutates `Shell.bashCurrent.environment`
        // sees its mutations within the launch but the parent shell is
        // untouched on the way out.
        let shell = Shell()
        shell.environment["PARENT_KEY"] = "parent"
        shell.installShellBuiltin(name: "tamper") { _ in
            Shell.bashCurrent.environment["LEAKED"] = "yes"
            return .success
        }

        var overrideEnv = shell.environment
        overrideEnv["RUNTIME_OVERRIDE"] = "v"

        try await shell.withCurrent {
            _ = try await shell.processLauncher.launch(
                .name("tamper"),
                arguments: [],
                environment: overrideEnv,
                workingDirectory: nil,
                input: .empty,
                output: .discard,
                error: .discard)
        }

        #expect(shell.environment["LEAKED"] == nil)
        #expect(shell.environment["RUNTIME_OVERRIDE"] == nil)
        #expect(shell.environment["PARENT_KEY"] == "parent")
    }
}

// MARK: Helpers

private final class BufferingSink: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var buf = Data()
    }
    private let box = Box()
    let sink: OutputSink

    init() {
        let box = self.box
        self.sink = OutputSink(onWrite: { data in
            box.lock.lock(); defer { box.lock.unlock() }
            box.buf.append(data)
        })
    }

    var text: String {
        box.lock.lock(); defer { box.lock.unlock() }
        // swiftlint:disable:next optional_data_string_conversion - test captures may include partial bytes
        return String(decoding: box.buf, as: UTF8.self)
    }
}

private final class ArgvCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var argv: [String] = []
    func set(_ values: [String]) {
        lock.lock(); defer { lock.unlock() }
        argv = values
    }
    var value: [String] {
        lock.lock(); defer { lock.unlock() }
        return argv
    }
}
