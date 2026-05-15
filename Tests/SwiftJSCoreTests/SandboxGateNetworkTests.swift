import XCTest
@testable import SwiftJSCore
import BashInterpreter
import BashCommandKit

#if !os(Windows)  // SwiftJSCore links the JSC C API everywhere except Windows for now

/// `fetch` / `child_process` gate coverage for `SandboxGate…`. Split
/// out of `SandboxGateTests` so neither class trips the
/// `type_body_length` lint.
final class SandboxGateNetworkTests: XCTestCase {

    // MARK: - fetch / network gate

    func testFetchDeniedWhenURLNotInAllowList() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let config = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://allowed.example.com")],
            allowedMethods: [.GET]
        )

        await SandboxGateTestSupport.withSandboxedShell(networkConfig: config) {
            let promise = runtime.run(#"""
            globalThis.__fetchOutcome = "(unset)";
            fetch('https://denied.example.com/x')
              .then(_ => { globalThis.__fetchOutcome = 'resolved'; })
              .catch(e => { globalThis.__fetchOutcome = `${e.code}|${e.message}`; });
            """#)
            _ = promise
            // Run the runloop briefly so the rejection propagates.
            runtime.run("(() => { for (let i=0;i<3;i++) Promise.resolve().then(()=>{}); })();")
            let outcome = runtime.run("globalThis.__fetchOutcome")?.toString() ?? ""
            XCTAssertTrue(outcome.hasPrefix("EACCES|"), "got: \(outcome)")
            XCTAssertTrue(outcome.contains("URL not in allow-list"),
                          "got: \(outcome)")
        }
    }

    func testFetchDeniedForBlockedMethod() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let config = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://allowed.example.com")],
            allowedMethods: [.GET]  // POST not allowed
        )

        await SandboxGateTestSupport.withSandboxedShell(networkConfig: config) {
            runtime.run(#"""
            globalThis.__fetchOutcome = "(unset)";
            fetch('https://allowed.example.com/x', { method: 'POST' })
              .then(_ => { globalThis.__fetchOutcome = 'resolved'; })
              .catch(e => { globalThis.__fetchOutcome = `${e.code}|${e.message}`; });
            """#)
            runtime.run("(() => { for (let i=0;i<3;i++) Promise.resolve().then(()=>{}); })();")
            let outcome = runtime.run("globalThis.__fetchOutcome")?.toString() ?? ""
            XCTAssertTrue(outcome.contains("HTTP method POST not in allow-list"),
                          "got: \(outcome)")
        }
    }

    func testFetchDeniedForUnknownHTTPMethod() async {
        // Earlier the gate fell back to `.GET` when `HTTPMethod(rawValue:)`
        // returned nil, so `fetch(url, { method: "FOO" })` would be
        // evaluated against GET permissions and pass when only GET was
        // allowed — even though the actual request method stayed `FOO`.
        // Unknown verbs must be rejected outright.
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let config = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://allowed.example.com")],
            allowedMethods: [.GET, .POST, .PUT, .DELETE, .HEAD, .PATCH, .OPTIONS]
        )

        await SandboxGateTestSupport.withSandboxedShell(networkConfig: config) {
            runtime.run(#"""
            globalThis.__fetchOutcome = "(unset)";
            fetch('https://allowed.example.com/x', { method: 'FOO' })
              .then(_ => { globalThis.__fetchOutcome = 'resolved'; })
              .catch(e => { globalThis.__fetchOutcome = `${e.code}|${e.message}`; });
            """#)
            runtime.run("(() => { for (let i=0;i<3;i++) Promise.resolve().then(()=>{}); })();")
            let outcome = runtime.run("globalThis.__fetchOutcome")?.toString() ?? ""
            XCTAssertTrue(outcome.contains("HTTP method FOO not supported"),
                          "got: \(outcome)")
        }
    }

    // MARK: - child_process gate

    func testSpawnDeniedUnderSandbox() async {
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox) {
            let result = runtime.run(#"""
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
        let runtime = SandboxGateTestSupport.makeRuntime().runtime
        let (sandbox, root) = SandboxGateTestSupport.makeRootedSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        await SandboxGateTestSupport.withSandboxedShell(sandbox: sandbox) {
            let result = runtime.run(#"""
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
}

#endif
