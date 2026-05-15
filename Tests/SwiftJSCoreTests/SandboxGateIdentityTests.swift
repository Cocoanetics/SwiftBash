import XCTest
@testable import SwiftJSCore
import BashInterpreter
import BashCommandKit

#if !os(Windows)  // SwiftJSCore links the JSC C API everywhere except Windows for now

/// Identity-redirect coverage for `SandboxGate…`: `process.env`,
/// `process.pid`, `process.cwd()`, `process.chdir()`, `os.hostname()`.
/// Split out of `SandboxGateTests` so neither class trips the
/// `type_body_length` lint.
final class SandboxGateIdentityTests: XCTestCase {

    func testProcessEnvRoutesThroughBoundShell() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime

        // FOO=bar in the runtime's envProvider, but BAZ=qux only in
        // the bound Shell's environment. Under the bound shell, only
        // BAZ should resolve — FOO must NOT leak through.
        await SandboxGateTestSupport.withSandboxedShell(env: ["BAZ": "qux"]) {
            let baz = runtime.run("process.env.BAZ")?.toString() ?? ""
            XCTAssertEqual(baz, "qux")
            let foo = runtime.run("process.env.FOO")
            XCTAssertTrue(foo?.isUndefined ?? false || foo?.toString() == "undefined",
                          "FOO must not leak through the bound shell")
        }
    }

    func testProcessPidReturnsVirtualPID() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        await SandboxGateTestSupport.withSandboxedShell(virtualPID: 42) {
            let pid = runtime.run("process.pid")?.toInt32() ?? -1
            XCTAssertEqual(pid, 42)
        }
    }

    func testProcessCwdReturnsBoundWorkingDirectory() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        await SandboxGateTestSupport.withSandboxedShell(cwd: "/sandboxed/path") {
            let cwd = runtime.run("process.cwd()")?.toString() ?? ""
            XCTAssertEqual(cwd, "/sandboxed/path")
        }
    }

    func testProcessChdirDeniedOutsideSandbox() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox, cwd: root.path) {
            runtime.run(#"""
            try { process.chdir('/etc'); globalThis.__chdirOutcome = 'no-throw'; }
            catch (e) { globalThis.__chdirOutcome = e.code; }
            """#)
            let outcome = runtime.run("globalThis.__chdirOutcome")?.toString() ?? ""
            XCTAssertEqual(outcome, "EACCES")
        }
    }

    func testRelativePathResolvedAgainstBoundShellCWDAfterChdir() async throws {
        // After `process.chdir(boundDir)`, a subsequent
        // `fs.readFileSync("./marker")` must resolve relative to the
        // bound shell's logical CWD — not the host process CWD. Earlier
        // the relative-path resolution happened via `URL(fileURLWithPath:)`
        // which uses host CWD, so `process.cwd()` and the actual file
        // read diverged: the gate authorised the wrong path and the
        // open failed (or succeeded against the wrong file).
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        // Drop a sentinel so a relative read can find it once we chdir
        // the bound shell into `root`.
        try Data("inside".utf8).write(
            to: root.appendingPathComponent("marker"))

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox, cwd: "/somewhere/else") {
            // `chdir` into root (an allowed write under the rooted
            // sandbox), then read `./marker` — which must resolve to
            // `<root>/marker` for both the gate and the open.
            let result = runtime.run(#"""
            process.chdir('\#(root.path)');
            require('fs').readFileSync('./marker', 'utf-8');
            """#)
            XCTAssertEqual(result?.toString(), "inside")
        }
    }

    func testChdirAcceptsRelativePath() async throws {
        // `process.chdir('./sub')` after `chdir('/work')` must end up
        // at `/work/sub`. Storing the raw "./sub" into
        // `Shell.current.environment.workingDirectory` would leave the
        // bound CWD unusable for any subsequent `fs.*` op.
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true)
        try Data("leaf".utf8).write(
            to: sub.appendingPathComponent("file"))

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox, cwd: root.path) {
            // chdir('./sub') is relative — must compose with the
            // existing bound CWD (root). Then a relative read
            // `./file` resolves into <root>/sub/file.
            let cwd = runtime.run(#"""
            process.chdir('./sub');
            process.cwd();
            """#)?.toString() ?? ""
            XCTAssertEqual(cwd, sub.path)

            let leaf = runtime.run(#"require('fs').readFileSync('./file', 'utf-8')"#)?
                .toString() ?? ""
            XCTAssertEqual(leaf, "leaf")
        }
    }

    func testOsHostnameReflectsBoundShell() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        await SandboxGateTestSupport.withSandboxedShell(hostName: "fake-host") {
            let hostname = runtime.run("require('os').hostname()")?.toString() ?? ""
            XCTAssertEqual(hostname, "fake-host")
        }
    }
}

#endif
