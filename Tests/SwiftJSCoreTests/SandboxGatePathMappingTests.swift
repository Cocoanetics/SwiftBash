import XCTest
@testable import SwiftJSCore
import BashInterpreter
import BashCommandKit

#if !os(Windows)  // SwiftJSCore links the JSC C API everywhere except Windows for now

/// The #83 contract for the JS runtime: under a shell whose sandbox
/// carries a `PathMapping` (the SwiftBash `--sandbox` shape), every
/// `fs.*` / `require` / `process.chdir` resolves the script's VIRTUAL
/// spelling to the mapped HOST directory for both the gate and the
/// I/O — while everything the script gets to *see* (`process.cwd()`,
/// `os.tmpdir()`, `__filename`) stays in the virtual spelling.
final class SandboxGatePathMappingTests: XCTestCase {

    /// Workspace + per-instance temp dir, mapping, and the `.confined`
    /// sandbox over them — the same wiring `swift-bash exec --sandbox`
    /// installs. Caller removes both dirs.
    private struct MappedFixture {
        let workspace: URL
        let temp: URL
        let sandbox: Sandbox

        func cleanup() {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func makeMappedSandbox() -> MappedFixture {
        let base = FileManager.default.temporaryDirectory
        let workspace = base.appendingPathComponent(
            "swiftjs-ws-\(UUID().uuidString)", isDirectory: true)
        let temp = base.appendingPathComponent(
            "swiftbash-js-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: temp, withIntermediateDirectories: true)
        let mapping = PathMapping(mounts: [
            .init(virtual: "/batch", host: workspace.path),
            .init(virtual: "/tmp", host: temp.path)
        ])
        let sandbox = Sandbox.confined(to: mapping,
                                       home: "/batch",
                                       temporaryDirectory: temp)
        return MappedFixture(workspace: workspace, temp: temp,
                             sandbox: sandbox)
    }

    func testFsWritesVirtualTmpIntoInstanceTempDir() async throws {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let fixture = makeMappedSandbox()
        defer { fixture.cleanup() }

        await SandboxGateTestSupport.withSandboxedShell(
            sandbox: fixture.sandbox, cwd: "/batch") {
            let result = runtime.run(#"""
            const fs = require('fs');
            fs.writeFileSync('/tmp/probe.txt', 'scratch');
            `${fs.existsSync('/tmp/probe.txt')}|`
              + fs.readFileSync('/tmp/probe.txt', 'utf-8');
            """#)
            XCTAssertEqual(result?.toString(), "true|scratch")
        }

        // The bytes landed in THIS instance's temp dir — not the
        // host's shared `/tmp` (#82).
        let hostFile = fixture.temp.appendingPathComponent("probe.txt")
        XCTAssertEqual(
            try String(contentsOf: hostFile, encoding: .utf8), "scratch")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: "/tmp/probe.txt"))
    }

    func testRelativePathsResolveAgainstVirtualCwd() async throws {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let fixture = makeMappedSandbox()
        defer { fixture.cleanup() }

        await SandboxGateTestSupport.withSandboxedShell(
            sandbox: fixture.sandbox, cwd: "/batch") {
            _ = runtime.run(#"""
            require('fs').writeFileSync('relative.txt', 'in-workspace');
            """#)
        }
        let hostFile = fixture.workspace
            .appendingPathComponent("relative.txt")
        XCTAssertEqual(
            try String(contentsOf: hostFile, encoding: .utf8),
            "in-workspace")
    }

    func testChdirKeepsVirtualCwdAndTranslatesIO() async throws {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let fixture = makeMappedSandbox()
        defer { fixture.cleanup() }

        await SandboxGateTestSupport.withSandboxedShell(
            sandbox: fixture.sandbox, cwd: "/batch") {
            let result = runtime.run(#"""
            process.chdir('/tmp');
            require('fs').writeFileSync('./after-chdir.txt', 'moved');
            process.cwd();
            """#)
            // The script-visible cwd stays virtual…
            XCTAssertEqual(result?.toString(), "/tmp")
        }
        // …while the write landed in the mapped host dir.
        let hostFile = fixture.temp
            .appendingPathComponent("after-chdir.txt")
        XCTAssertEqual(
            try String(contentsOf: hostFile, encoding: .utf8), "moved")
    }

    func testOsAnswersStayVirtual() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let fixture = makeMappedSandbox()
        defer { fixture.cleanup() }

        await SandboxGateTestSupport.withSandboxedShell(
            sandbox: fixture.sandbox,
            env: ["HOME": "/batch"], cwd: "/batch") {
            let result = runtime.run(#"""
            const os = require('os');
            `${os.tmpdir()}|${os.homedir()}`;
            """#)
            // Host per-instance paths fold back to the virtual
            // spellings — nothing about the embedder's disk layout
            // leaks into the script.
            XCTAssertEqual(result?.toString(), "/tmp|/batch")
        }
    }

    func testPathsOutsideMountsAreDenied() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let fixture = makeMappedSandbox()
        defer { fixture.cleanup() }

        await SandboxGateTestSupport.withSandboxedShell(
            sandbox: fixture.sandbox, cwd: "/batch") {
            let result = runtime.run(#"""
            const fs = require('fs');
            let write;
            try {
              fs.writeFileSync('/etc/should-not-exist', 'x');
              write = 'no-throw';
            } catch (e) { write = e.code; }
            `${write}|${fs.existsSync('/etc/passwd')}`;
            """#)
            XCTAssertEqual(result?.toString(), "EACCES|false")
        }
    }

    func testRequireLoadsModulesThroughTheMapping() async throws {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let fixture = makeMappedSandbox()
        defer { fixture.cleanup() }

        // Seed a module on the host side of the workspace mount.
        let module = fixture.workspace.appendingPathComponent("mod.js")
        try Data("""
        module.exports = { tag: 'loaded', file: __filename };
        """.utf8).write(to: module)

        await SandboxGateTestSupport.withSandboxedShell(
            sandbox: fixture.sandbox, cwd: "/batch") {
            let result = runtime.run(#"""
            const m = require('/batch/mod.js');
            `${m.tag}|${m.file}`;
            """#)
            // The module loads through the mapping, and __filename
            // carries the VIRTUAL spelling.
            XCTAssertEqual(result?.toString(), "loaded|/batch/mod.js")
        }
    }

    func testRequireSymlinkEscapeIsNotAnExistenceOracle() async throws {
        // Codex P2 on #88: `require` probed `fileExists` on the
        // translated host path BEFORE authorizing, so a workspace
        // symlink escaping the sandbox let a script distinguish an
        // existing outside target from a missing one by the error
        // shape. The gate now runs first and a denied candidate folds
        // into MODULE_NOT_FOUND — so both escapes look identical.
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let fixture = makeMappedSandbox()
        defer { fixture.cleanup() }

        // Two workspace symlinks: one to an existing outside file,
        // one to a guaranteed-missing path. Both escape the mount.
        let existingOutside = fixture.workspace
            .appendingPathComponent("link-existing").path
        try FileManager.default.createSymbolicLink(
            atPath: existingOutside, withDestinationPath: "/etc/hosts")
        let missingOutside = fixture.workspace
            .appendingPathComponent("link-missing").path
        try FileManager.default.createSymbolicLink(
            atPath: missingOutside,
            withDestinationPath: "/no/such/path-\(UUID().uuidString)")

        await SandboxGateTestSupport.withSandboxedShell(
            sandbox: fixture.sandbox, cwd: "/batch") {
            let probe = #"""
            (name) => {
              try { require(name); return 'loaded'; }
              catch (e) { return e.code; }
            }
            """#
            let tryRequire = runtime.run(probe)!
            let existing = tryRequire.call(
                withArguments: ["/batch/link-existing"])
            let missing = tryRequire.call(
                withArguments: ["/batch/link-missing"])
            // Identical outcome — no oracle — and specifically the
            // not-found shape, never EACCES that would confirm the
            // escape reached an existing file.
            XCTAssertEqual(existing?.toString(), "MODULE_NOT_FOUND")
            XCTAssertEqual(missing?.toString(), "MODULE_NOT_FOUND")
        }
    }
}

#endif
