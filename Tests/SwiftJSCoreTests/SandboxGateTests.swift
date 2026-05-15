import XCTest
@testable import SwiftJSCore
import BashInterpreter
import BashCommandKit

// `testStandalonePidIsRealPID` calls `getpid()` directly, which
// only resolves through Foundation on Apple. Pick up the libc
// module explicitly so the test compiles on Linux + Android too.
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if !os(Windows)  // SwiftJSCore links the JSC C API everywhere except Windows for now

/// Verifies that every host-touching JS surface in SwiftJSCore consults
/// the bound `Shell`'s `sandbox` / `networkConfig` and the synthetic
/// identity fields on `hostInfo` / `environment`. Mirrors the pattern
/// `SwiftScript`'s `ShellKitIntegrationTests` use: bind a shell with a
/// confining sandbox, run a JS snippet, assert the JS-side error shape
/// or the redirected value.
///
/// This class covers the `fs` gate plus the standalone-passthrough
/// (no-shell-bound) tests. The fetch / network / child-process /
/// identity-redirect tests live in their own sibling classes; see
/// `SandboxGateNetworkTests` and `SandboxGateIdentityTests`.
final class SandboxGateTests: XCTestCase {

    // MARK: - fs gate

    func testReadFileSyncDeniedOutsideSandboxRoot() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox) {
            let result = runtime.run(#"""
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
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let allowed = root.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: allowed)

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox) {
            let result = runtime.run(#"""
            require('fs').readFileSync('\#(allowed.path)', 'utf-8');
            """#)
            XCTAssertEqual(result?.toString(), "hello")
        }
    }

    func testWriteFileSyncDeniedOutsideRoot() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox) {
            let result = runtime.run(#"""
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
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox) {
            let result = runtime.run(#"""
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
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox) {
            let result = runtime.run("require('fs').existsSync('/etc/passwd')")
            XCTAssertEqual(result?.toBool(), false)
        }
    }

    func testRequireRelativeDeniedOutsideRoot() async throws {
        let fixture = SandboxGateTestSupport.makeRuntime()
        let runtime = fixture.runtime
        let err = fixture.stderr
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        // Stage a module *outside* the sandbox root.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftjs-outside-\(UUID().uuidString).js")
        try Data("module.exports = 'leaked';".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox) {
            runtime.run(#"""
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

    // MARK: - standalone passthrough (no Shell bound)

    func testStandaloneFsReadsHostFiles() throws {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftjs-standalone-\(UUID().uuidString).txt")
        try Data("passthrough".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // No Shell.withCurrent — Shell.processDefault is in scope, so
        // every gate must be a no-op.
        let value = runtime.run(#"require('fs').readFileSync('\#(tmp.path)', 'utf-8')"#)?.toString()
        XCTAssertEqual(value, "passthrough")
    }

    func testStandalonePidIsRealPID() {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let pid = runtime.run("process.pid")?.toInt32() ?? -1
        XCTAssertEqual(pid, getpid())
    }
}

#endif
