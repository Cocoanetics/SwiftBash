import Testing
import Foundation
@testable import BashInterpreter

@Suite(.timeLimit(.minutes(1))) struct ScriptInterpreterTests {

    /// Drop a shebang script onto disk with the execute bit set —
    /// the dispatcher refuses non-executable regular files (matches
    /// `bash ./script` semantics on a real system).
    private static func writeExecutable(
        _ source: String,
        to path: String
    ) throws {
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path)
    }

    /// POSIX-style single-quote a path so it survives bash's word-
    /// expansion intact. Critical on Windows: `NSTemporaryDirectory()`
    /// returns paths with `\` separators, and unquoted `\X` is a bash
    /// escape — the path makes it to `cap.shell.run(...)` with every
    /// backslash already eaten, so the dispatcher never sees a
    /// `/`-bearing token and falls through to `command not found`.
    /// Embedded single quotes are encoded as `'\''` (the standard
    /// POSIX trick); UUID-bearing test paths don't contain quotes,
    /// but the helper is correct in general.
    private static func bashQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: parseShebangLine

    @Test func parsesPlainShebang() {
        let parsed = parseShebangLine("#!/bin/bash")
        #expect(parsed?.interpreter == "bash")
        #expect(parsed?.argv == ["/bin/bash"])
    }

    @Test func parsesShebangWithArgs() {
        let parsed = parseShebangLine("#!/usr/bin/python3 -O")
        #expect(parsed?.interpreter == "python3")
        #expect(parsed?.argv == ["/usr/bin/python3", "-O"])
    }

    @Test func parsesEnvPrefixedShebang() {
        let parsed = parseShebangLine("#!/usr/bin/env swift-script")
        #expect(parsed?.interpreter == "swift-script")
        #expect(parsed?.argv == ["swift-script"])
    }

    @Test func parsesEnvPrefixedShebangWithFlags() {
        // env -S splits its arg into multiple tokens upstream; once
        // tokenised, we should walk past the -S flag and resolve the
        // real interpreter.
        let parsed = parseShebangLine("#!/usr/bin/env -S swift-script --strict")
        #expect(parsed?.interpreter == "swift-script")
        #expect(parsed?.argv == ["swift-script", "--strict"])
    }

    @Test func parsesEnvWithKeyValueOverrides() {
        let parsed = parseShebangLine(
            "#!/usr/bin/env FOO=bar BAZ=qux python3")
        #expect(parsed?.interpreter == "python3")
        #expect(parsed?.argv == ["python3"])
    }

    @Test func tolerantOfLeadingWhitespace() {
        let parsed = parseShebangLine("#!  /usr/bin/swift-script")
        #expect(parsed?.interpreter == "swift-script")
    }

    @Test func rejectsNonShebangLine() {
        #expect(parseShebangLine("// not a shebang") == nil)
        #expect(parseShebangLine("# just a comment") == nil)
        #expect(parseShebangLine("") == nil)
    }

    @Test func envWithoutTargetReturnsNil() {
        // `#!/usr/bin/env` with nothing after it is meaningless — the
        // kernel would error out. We return nil so the caller falls
        // through to "command not found".
        #expect(parseShebangLine("#!/usr/bin/env") == nil)
    }

    // MARK: stripShebang

    @Test func stripShebangRemovesLineButKeepsNewline() {
        // The shebang content is dropped, but the trailing newline is
        // retained so line numbers below stay aligned with the
        // original file. Body therefore begins with "\n".
        let (stripped, line) = stripShebang(
            "#!/usr/bin/env swift-script\nprint(1)\n")
        #expect(stripped == "\nprint(1)\n")
        #expect(line == "#!/usr/bin/env swift-script")
    }

    @Test func stripShebangPreservesLineNumbers() {
        // Line 2 in the body is the same as line 2 in the original.
        // Interpreter diagnostics that report "line N" therefore
        // point at the same physical line the user sees.
        let original = "#!/bin/bash\necho hi\necho bye\n"
        let (stripped, _) = stripShebang(original)
        let originalLines = original.split(separator: "\n",
                                           omittingEmptySubsequences: false)
        let strippedLines = stripped.split(separator: "\n",
                                           omittingEmptySubsequences: false)
        #expect(originalLines.count == strippedLines.count)
        #expect(originalLines[1] == strippedLines[1])
        #expect(originalLines[2] == strippedLines[2])
    }

    @Test func stripShebangNoOpForNonShebang() {
        let (stripped, line) = stripShebang("print(\"hi\")\n")
        #expect(stripped == "print(\"hi\")\n")
        #expect(line == nil)
    }

    @Test func stripShebangWithoutTrailingNewline() {
        // Pure shebang, no body — body strips to empty.
        let (stripped, line) = stripShebang("#!/bin/sh")
        #expect(stripped == "")
        #expect(line == "#!/bin/sh")
    }

    // MARK: end-to-end dispatch

    @Test func registeredInterpreterRunsOnPathInvocation() async throws {
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = dir + "/hello.foo"
        try Self.writeExecutable("#!/usr/bin/env foolang\nbody\n", to: path)

        // Capture every interpreter invocation so we can assert on
        // what the dispatcher hands over.
        actor Sink {
            var contexts: [ScriptInterpreterContext] = []
            func record(_ ctx: ScriptInterpreterContext) { contexts.append(ctx) }
        }
        let sink = Sink()
        cap.shell.registerScriptInterpreter(name: "foolang") { ctx in
            await sink.record(ctx)
            Shell.current.stdout("ran:\(ctx.argv.joined(separator: ","))\n")
            return .success
        }

        try await cap.shell.run("\(Self.bashQuote(path)) one two")
        let ctxs = await sink.contexts
        #expect(ctxs.count == 1)
        // The dispatcher hands over the *resolved* path (drive-letter
        // forward-slash form on Windows; identity on Unix). Compute
        // the expected form via the same `resolvePath` so the
        // assertion stays platform-independent.
        let resolvedPath = cap.shell.resolvePath(path)
        #expect(ctxs.first?.scriptPath == resolvedPath)
        #expect(ctxs.first?.shebang == "#!/usr/bin/env foolang")
        #expect(ctxs.first?.argv == [resolvedPath, "one", "two"])
        // Body should be stripped — no leading `#!` survives. The
        // newline is retained so line 2 of the file is still line 2
        // of the body.
        #expect(ctxs.first?.source.hasPrefix("#!") == false)
        #expect(ctxs.first?.source.hasPrefix("\n") == true)
        #expect(cap.stdout == "ran:\(resolvedPath),one,two\n")
    }

    @Test func dispatchPropagatesPositionalsToScript() async throws {
        // The interpreter's body reads `Shell.current.positionalParameters`
        // — the dispatcher should have set them to argv[1...].
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-pos-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.foo"
        try Self.writeExecutable("#!/usr/bin/env foolang\n", to: path)
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in
            let pos = Shell.current.positionalParameters
            Shell.current.stdout(
                "$0=\(Shell.current.scriptName) $@=\(pos.joined(separator: " "))\n")
            return .success
        }
        try await cap.shell.run("\(Self.bashQuote(path)) alpha beta gamma")
        let resolvedPath = cap.shell.resolvePath(path)
        #expect(cap.stdout == "$0=\(resolvedPath) $@=alpha beta gamma\n")
    }

    @Test func parentPositionalsArePreservedAfterDispatch() async throws {
        // Subshell isolation — the dispatched script must not leak its
        // positional parameters into the parent shell.
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-iso-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.foo"
        try Self.writeExecutable("#!/usr/bin/env foolang\n", to: path)
        cap.shell.scriptName = "outer"
        cap.shell.positionalParameters = ["outerArg"]
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in
            return .success
        }
        try await cap.shell.run("\(Self.bashQuote(path)) inner")
        #expect(cap.shell.scriptName == "outer")
        #expect(cap.shell.positionalParameters == ["outerArg"])
    }

    @Test func interpreterExitStatusFlowsThroughToParent() async throws {
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-exit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.foo"
        try Self.writeExecutable("#!/usr/bin/env foolang\n", to: path)
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in
            ExitStatus(7)
        }
        try await cap.shell.run("\(Self.bashQuote(path)); echo $?")
        #expect(cap.stdout == "7\n")
    }

    @Test func nonExistentPathReturns127() async throws {
        let cap = CapturingShell()
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in .success }
        let bogus = "/tmp/swift-bash-no-such-script-\(UUID().uuidString)"
        let status = try await cap.shell.run("\(bogus)")
        #expect(status.code == 127)
        #expect(cap.stderr.contains("No such file or directory"))
    }

    @Test func directoryReturns126() async throws {
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-dir-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in .success }
        let status = try await cap.shell.run(Self.bashQuote(dir))
        #expect(status.code == 126)
        #expect(cap.stderr.contains("Is a directory"))
    }

    @Test func bareNameNotTreatedAsPath() async throws {
        // `swift-script` without a `/` in it must NOT trigger external
        // dispatch, even when an interpreter is registered. Bare names
        // go through the command registry only.
        let cap = CapturingShell()
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in
            ExitStatus(0)
        }
        let status = try await cap.shell.run("swift-script-not-a-real-cmd")
        #expect(status.code == 127)
        #expect(cap.stderr.contains("command not found"))
    }

    #if !os(Windows)
    @Test func nonExecutableScriptRejectedWithPermissionDenied() async throws {
        // A regular file with a matching shebang but no execute bit
        // is rejected with 126 / "Permission denied" — matches bash
        // `./script` when the file isn't `chmod +x`'d. Without this
        // check, the dispatcher would happily run a 0644 file the
        // user never marked as runnable.
        //
        // Skipped on Windows: there's no POSIX execute bit there, so
        // `setAttributes(posixPermissions:)` is a no-op and the
        // dispatcher's executable-bit check is disabled (see
        // `Shell+ExternalScript.swift`). The test concept doesn't
        // map to the platform.
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-perm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.foo"
        try "#!/usr/bin/env foolang\n".write(
            toFile: path, atomically: true, encoding: .utf8)
        // 0644 — readable, writable by owner, NOT executable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: path)
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in
            Issue.record("interpreter should not have been invoked")
            return .success
        }
        let status = try await cap.shell.run(Self.bashQuote(path))
        #expect(status.code == 126)
        #expect(cap.stderr.contains("Permission denied"))
    }
    #endif

    @Test func unreadableScriptReportsPermissionDenied() async throws {
        // A path the FS rejects (sandbox denial, EACCES) on `metadata`
        // / `readData` should surface as 126 with a permission-shaped
        // diagnostic — masking it as `command not found` (the prior
        // behaviour) hid real failures behind a misleading message.
        let cap = CapturingShell()
        // FailingFileSystem rejects everything with permissionDenied
        // so we exercise the "explicit path, FS error" branch.
        cap.shell.fileSystem = FailingFileSystem()
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in .success }
        let status = try await cap.shell.run("/some/explicit/path")
        #expect(status.code == 126)
        #expect(cap.stderr.contains("Permission denied"))
    }

    @Test func unregisteredShebangFallsThroughToCommandNotFound() async throws {
        // File exists with a shebang naming an interpreter we DON'T
        // have. We don't synthesize a "no interpreter for X" error
        // because falling through to bash's "command not found" lets
        // PATH lookups (etc.) still take effect for bare names.
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-unreg-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.foo"
        try Self.writeExecutable("#!/usr/bin/env nope-lang\n", to: path)
        let status = try await cap.shell.run("\(Self.bashQuote(path))")
        #expect(status.code == 127)
        #expect(cap.stderr.contains("command not found"))
    }

    @Test func interpretersInheritIntoSubshells() async throws {
        // The registry must propagate via Shell.copy() so subshells
        // dispatch the same interpreters.
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-sub-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.foo"
        try Self.writeExecutable("#!/usr/bin/env foolang\n", to: path)
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in
            Shell.current.stdout("ok\n")
            return .success
        }
        try await cap.shell.run("(\(Self.bashQuote(path)))")
        #expect(cap.stdout == "ok\n")
    }

    @Test func dispatchedSourceMatchesOriginalLineNumbers() async throws {
        // An error on line 3 of the original file should arrive at
        // line 3 of the body the interpreter sees. We don't have a
        // concrete error path in the test interpreter, so check the
        // body structure directly: line N in the body equals line N
        // in the original file (line 1 is empty where the shebang
        // was).
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-lines-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.foo"
        let original = """
            #!/usr/bin/env foolang
            print(1)
            print(2)

            """
        try Self.writeExecutable(original, to: path)
        actor Sink {
            var source: String?
            func record(_ src: String) { source = src }
        }
        let sink = Sink()
        cap.shell.registerScriptInterpreter(name: "foolang") { ctx in
            await sink.record(ctx.source)
            return .success
        }
        try await cap.shell.run(Self.bashQuote(path))
        let body = await sink.source ?? ""
        let originalLines = original.split(separator: "\n",
                                           omittingEmptySubsequences: false)
        let bodyLines = body.split(separator: "\n",
                                   omittingEmptySubsequences: false)
        #expect(originalLines.count == bodyLines.count)
        #expect(bodyLines[0] == "")           // shebang stripped
        #expect(bodyLines[1] == "print(1)")   // line 2 unchanged
        #expect(bodyLines[2] == "print(2)")   // line 3 unchanged
    }

    @Test func unregisterRemovesInterpreter() async throws {
        let cap = CapturingShell()
        let dir = NSTemporaryDirectory()
            + "swift-bash-shebang-unreg2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/run.foo"
        try Self.writeExecutable("#!/usr/bin/env foolang\nbody", to: path)
        cap.shell.registerScriptInterpreter(name: "foolang") { _ in .success }
        cap.shell.unregisterScriptInterpreter("foolang")
        let status = try await cap.shell.run("\(Self.bashQuote(path))")
        #expect(status.code == 127)
    }
}

// MARK: - Test helpers

/// Synthetic FS that rejects every read with `permissionDenied`.
/// Used to drive the dispatcher's explicit-path FS-error branch
/// without depending on chmod-able real disk state.
private struct FailingFileSystem: FileSystem {
    func metadata(_ path: String) async throws -> FileMetadata? {
        throw FileSystemError.permissionDenied(path)
    }
    func list(_ path: String) async throws -> [FileEntry] {
        throw FileSystemError.permissionDenied(path)
    }
    func canonicalize(_ path: String, allowMissing: Bool) async throws -> String {
        path
    }
    func readData(_ path: String) async throws -> Data {
        throw FileSystemError.permissionDenied(path)
    }
    func writeData(_ data: Data, to path: String, append: Bool) async throws {
        throw FileSystemError.permissionDenied(path)
    }
    func touch(_ path: String) async throws {
        throw FileSystemError.permissionDenied(path)
    }
    func createDirectory(_ path: String, intermediates: Bool) async throws {
        throw FileSystemError.permissionDenied(path)
    }
    func remove(_ path: String, recursive: Bool) async throws {
        throw FileSystemError.permissionDenied(path)
    }
    func move(from: String, to: String) async throws {
        throw FileSystemError.permissionDenied(from)
    }
    func copy(from: String, to: String) async throws {
        throw FileSystemError.permissionDenied(from)
    }
}
