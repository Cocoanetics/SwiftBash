import XCTest
@testable import SwiftJSCore
import BashInterpreter
import BashCommandKit

#if canImport(JavaScriptCore)

/// Verifies that every host-touching JS surface in SwiftJSCore consults
/// the bound `Shell`'s `sandbox` / `networkConfig` and the synthetic
/// identity fields on `hostInfo` / `environment`. Mirrors the pattern
/// `SwiftScript`'s `ShellKitIntegrationTests` use: bind a shell with a
/// confining sandbox, run a JS snippet, assert the JS-side error shape
/// or the redirected value.
final class SandboxGateTests: XCTestCase {

    // MARK: - Helpers

    private func makeRuntime() -> (JSRuntime, () -> String, () -> String) {
        var out = ""
        var err = ""
        let r = JSRuntime(
            argv: ["swift-js", "test.js"],
            env: ["FOO": "bar"],
            stdout: { out += $0 },
            stderr: { err += $0 }
        )
        return (r, { out }, { err })
    }

    private func withSandboxedShell(
        sandbox: Sandbox? = nil,
        networkConfig: NetworkConfig? = nil,
        env: [String: String] = [:],
        cwd: String? = nil,
        hostName: String = "sandbox",
        userName: String = "user",
        virtualPID: Int32 = 1,
        body: () -> Void
    ) async {
        let shell = Shell(
            environment: Environment(
                variables: env,
                workingDirectory: cwd ?? "/sandbox-cwd"
            ),
            sandbox: sandbox,
            networkConfig: networkConfig,
            hostInfo: {
                var info = HostInfo.synthetic
                info.userName = userName
                info.hostName = hostName
                info.nodeName = hostName
                return info
            }(),
            virtualPID: virtualPID
        )
        await shell.withCurrent { body() }
    }

    private func makeRootedSandbox() -> (Sandbox, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftjs-sandbox-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return (Sandbox.rooted(at: root, allowedHosts: []), root)
    }

    // MARK: - fs gate

    func testReadFileSyncDeniedOutsideSandboxRoot() async {
        let (r, _, _) = makeRuntime()
        let (sandbox, root) = makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await withSandboxedShell(sandbox: sandbox) {
            let result = r.run(#"""
            try {
              require('fs').readFileSync('/etc/passwd');
              'no-throw';
            } catch (e) {
              `${e.code}|${e.syscall}`;
            }
            """#)
            XCTAssertEqual(result?.toString(), "EACCES|open")
        }
    }

    func testReadFileSyncAllowedInsideSandboxRoot() async throws {
        let (r, _, _) = makeRuntime()
        let (sandbox, root) = makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let allowed = root.appendingPathComponent("note.txt")
        try "hello".data(using: .utf8)!.write(to: allowed)

        await withSandboxedShell(sandbox: sandbox) {
            let result = r.run(#"""
            require('fs').readFileSync('\#(allowed.path)', 'utf-8');
            """#)
            XCTAssertEqual(result?.toString(), "hello")
        }
    }

    func testWriteFileSyncDeniedOutsideRoot() async {
        let (r, _, _) = makeRuntime()
        let (sandbox, root) = makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await withSandboxedShell(sandbox: sandbox) {
            let result = r.run(#"""
            try {
              require('fs').writeFileSync('/tmp/should-not-exist.txt', 'x');
              'no-throw';
            } catch (e) {
              e.code;
            }
            """#)
            XCTAssertEqual(result?.toString(), "EACCES")
        }
    }

    func testStatSyncDenied() async {
        let (r, _, _) = makeRuntime()
        let (sandbox, root) = makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await withSandboxedShell(sandbox: sandbox) {
            let result = r.run(#"""
            try {
              require('fs').statSync('/etc');
              'no-throw';
            } catch (e) {
              e.code;
            }
            """#)
            XCTAssertEqual(result?.toString(), "EACCES")
        }
    }

    func testExistsSyncReturnsFalseOnDeny() async {
        let (r, _, _) = makeRuntime()
        let (sandbox, root) = makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await withSandboxedShell(sandbox: sandbox) {
            let result = r.run("require('fs').existsSync('/etc/passwd')")
            XCTAssertEqual(result?.toBool(), false)
        }
    }

    func testRequireRelativeDeniedOutsideRoot() async throws {
        let (r, _, err) = makeRuntime()
        let (sandbox, root) = makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        // Stage a module *outside* the sandbox root.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftjs-outside-\(UUID().uuidString).js")
        try "module.exports = 'leaked';".data(using: .utf8)!.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        await withSandboxedShell(sandbox: sandbox) {
            r.run(#"""
            try {
              const v = require('\#(outside.path)');
              console.log('LEAKED:' + v);
            } catch (e) {
              console.log('CODE:' + e.code);
            }
            """#)
        }
        let combined = err()  // throwSandboxDenial sets ctx.exception, which the
        XCTAssertFalse(combined.contains("LEAKED:leaked"),
                       "require should not have read outside-sandbox source")
    }

    // MARK: - fetch / network gate

    func testFetchDeniedWhenURLNotInAllowList() async {
        let (r, _, _) = makeRuntime()
        let config = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://allowed.example.com")],
            allowedMethods: [.GET]
        )

        await withSandboxedShell(networkConfig: config) {
            let promise = r.run(#"""
            globalThis.__fetchOutcome = "(unset)";
            fetch('https://denied.example.com/x')
              .then(_ => { globalThis.__fetchOutcome = 'resolved'; })
              .catch(e => { globalThis.__fetchOutcome = `${e.code}|${e.message}`; });
            """#)
            _ = promise
            // Run the runloop briefly so the rejection propagates.
            r.run("(() => { for (let i=0;i<3;i++) Promise.resolve().then(()=>{}); })();")
            let outcome = r.run("globalThis.__fetchOutcome")?.toString() ?? ""
            XCTAssertTrue(outcome.hasPrefix("EACCES|"), "got: \(outcome)")
            XCTAssertTrue(outcome.contains("URL not in allow-list"),
                          "got: \(outcome)")
        }
    }

    func testFetchDeniedForBlockedMethod() async {
        let (r, _, _) = makeRuntime()
        let config = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://allowed.example.com")],
            allowedMethods: [.GET]  // POST not allowed
        )

        await withSandboxedShell(networkConfig: config) {
            r.run(#"""
            globalThis.__fetchOutcome = "(unset)";
            fetch('https://allowed.example.com/x', { method: 'POST' })
              .then(_ => { globalThis.__fetchOutcome = 'resolved'; })
              .catch(e => { globalThis.__fetchOutcome = `${e.code}|${e.message}`; });
            """#)
            r.run("(() => { for (let i=0;i<3;i++) Promise.resolve().then(()=>{}); })();")
            let outcome = r.run("globalThis.__fetchOutcome")?.toString() ?? ""
            XCTAssertTrue(outcome.contains("HTTP method POST not in allow-list"),
                          "got: \(outcome)")
        }
    }

    // MARK: - child_process gate

    func testSpawnDeniedUnderSandbox() async {
        let (r, _, _) = makeRuntime()
        let (sandbox, root) = makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await withSandboxedShell(sandbox: sandbox) {
            let result = r.run(#"""
            try {
              require('child_process').spawn('whoami');
              'no-throw';
            } catch (e) {
              `${e.code}|${e.syscall}`;
            }
            """#)
            XCTAssertEqual(result?.toString(), "EACCES|spawn")
        }
    }

    func testExecSyncDeniedUnderSandbox() async {
        let (r, _, _) = makeRuntime()
        let (sandbox, root) = makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await withSandboxedShell(sandbox: sandbox) {
            let result = r.run(#"""
            try {
              require('child_process').execSync('echo hi');
              'no-throw';
            } catch (e) {
              e.code;
            }
            """#)
            XCTAssertEqual(result?.toString(), "EACCES")
        }
    }

    // MARK: - identity redirects

    func testProcessEnvRoutesThroughBoundShell() async {
        let (r, _, _) = makeRuntime()

        // FOO=bar in the runtime's envProvider, but BAZ=qux only in
        // the bound Shell's environment. Under the bound shell, only
        // BAZ should resolve — FOO must NOT leak through.
        await withSandboxedShell(env: ["BAZ": "qux"]) {
            let baz = r.run("process.env.BAZ")?.toString() ?? ""
            XCTAssertEqual(baz, "qux")
            let foo = r.run("process.env.FOO")
            XCTAssertTrue(foo?.isUndefined ?? false || foo?.toString() == "undefined",
                          "FOO must not leak through the bound shell")
        }
    }

    func testProcessPidReturnsVirtualPID() async {
        let (r, _, _) = makeRuntime()
        await withSandboxedShell(virtualPID: 42) {
            let pid = r.run("process.pid")?.toInt32() ?? -1
            XCTAssertEqual(pid, 42)
        }
    }

    func testProcessCwdReturnsBoundWorkingDirectory() async {
        let (r, _, _) = makeRuntime()
        await withSandboxedShell(cwd: "/sandboxed/path") {
            let cwd = r.run("process.cwd()")?.toString() ?? ""
            XCTAssertEqual(cwd, "/sandboxed/path")
        }
    }

    func testProcessChdirDeniedOutsideSandbox() async {
        let (r, _, _) = makeRuntime()
        let (sandbox, root) = makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await withSandboxedShell(sandbox: sandbox, cwd: root.path) {
            r.run(#"""
            try { process.chdir('/etc'); globalThis.__chdirOutcome = 'no-throw'; }
            catch (e) { globalThis.__chdirOutcome = e.code; }
            """#)
            let outcome = r.run("globalThis.__chdirOutcome")?.toString() ?? ""
            XCTAssertEqual(outcome, "EACCES")
        }
    }

    func testOsHostnameReflectsBoundShell() async {
        let (r, _, _) = makeRuntime()
        await withSandboxedShell(hostName: "fake-host") {
            let h = r.run("require('os').hostname()")?.toString() ?? ""
            XCTAssertEqual(h, "fake-host")
        }
    }

    // MARK: - standalone passthrough (no Shell bound)

    func testStandaloneFsReadsHostFiles() throws {
        let (r, _, _) = makeRuntime()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftjs-standalone-\(UUID().uuidString).txt")
        try "passthrough".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // No Shell.withCurrent — Shell.processDefault is in scope, so
        // every gate must be a no-op.
        let v = r.run(#"require('fs').readFileSync('\#(tmp.path)', 'utf-8')"#)?.toString()
        XCTAssertEqual(v, "passthrough")
    }

    func testStandalonePidIsRealPID() {
        let (r, _, _) = makeRuntime()
        let pid = r.run("process.pid")?.toInt32() ?? -1
        XCTAssertEqual(pid, getpid())
    }
}

#endif
