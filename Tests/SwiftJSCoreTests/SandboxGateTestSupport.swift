import XCTest
@testable import SwiftJSCore
import BashInterpreter
import BashCommandKit

#if !os(Windows)  // SwiftJSCore links the JSC C API everywhere except Windows for now

/// Shared helpers for the `SandboxGate…Tests` family. Each test class
/// is independent under XCTest, but they all want the same
/// runtime / shell-binding boilerplate. Lives at file scope so every
/// class in the target can reach it without subclassing.
enum SandboxGateTestSupport {

    struct RuntimeFixture {
        let runtime: JSRuntime
        let stdout: () -> String
        let stderr: () -> String
    }

    static func makeRuntime() -> RuntimeFixture {
        var out = ""
        var err = ""
        let runtime = JSRuntime(
            argv: ["swift-js", "test.js"],
            env: ["FOO": "bar"],
            stdout: { out += $0 },
            stderr: { err += $0 }
        )
        return RuntimeFixture(runtime: runtime, stdout: { out }, stderr: { err })
    }

    static func withSandboxedShell(
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

    static func makeRootedSandbox() -> (Sandbox, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftjs-sandbox-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return (Sandbox.rooted(at: root, allowedHosts: []), root)
    }
}

#endif
