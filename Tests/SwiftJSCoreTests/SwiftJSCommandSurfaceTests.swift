#if canImport(JavaScriptCore)
import XCTest
@testable import SwiftJSCore
import BashInterpreter
import BashCommandKit
import Foundation

/// Issue #37: in-process `node` / `bun` / `swift-js` must accept the
/// same argv shape as the standalone CLI — `--version`, `-e <expr>`,
/// `-p <expr>`, and `<script.js>`. Before the fix these only worked
/// via the script-interpreter (shebang) path, so a bare
/// `node --version` invocation failed.
final class SwiftJSCommandSurfaceTests: XCTestCase {

    private final class StringBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ data: Data) {
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

    private final class Capture: @unchecked Sendable {
        let stdoutSink: OutputSink
        let stderrSink: OutputSink
        private let outBox = StringBox()
        private let errBox = StringBox()
        var stdout: String { outBox.read() }
        var stderr: String { errBox.read() }
        init() {
            let out = outBox
            let err = errBox
            self.stdoutSink = OutputSink(onWrite: { out.append($0) })
            self.stderrSink = OutputSink(onWrite: { err.append($0) })
        }
    }

    private func makeShell() -> (Shell, Capture) {
        let cap = Capture()
        let shell = Shell(
            stdout: cap.stdoutSink,
            stderr: cap.stderrSink,
            environment: Environment(),
            commands: Shell.defaultCommands())
        shell.registerSwiftJS()
        return (shell, cap)
    }

    func testNodeVersionFlag() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("node --version")
        XCTAssertEqual(status.code, 0)
        XCTAssertTrue(cap.stdout.contains("v22"),
                      "unexpected version output: \(cap.stdout)")
    }

    func testBunVersionFlag() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("bun --version")
        XCTAssertEqual(status.code, 0)
        XCTAssertFalse(cap.stdout.isEmpty)
    }

    func testSwiftJsVersionFlag() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("swift-js --version")
        XCTAssertEqual(status.code, 0)
        XCTAssertTrue(cap.stdout.contains("swift-js"))
    }

    func testNodeDashE() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("node -e 'console.log(2 + 3)'")
        XCTAssertEqual(status.code, 0)
        XCTAssertEqual(cap.stdout, "5\n")
    }

    func testNodeDashPPrintsExpression() async throws {
        let (shell, cap) = makeShell()
        // `-p` evaluates and prints the resulting expression value.
        let status = try await shell.run("node -p '40 + 2'")
        XCTAssertEqual(status.code, 0)
        XCTAssertEqual(cap.stdout, "42\n")
    }

    func testBunDashE() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("bun -e 'console.log(\"hi\")'")
        XCTAssertEqual(status.code, 0)
        XCTAssertEqual(cap.stdout, "hi\n")
    }

    func testNodeDashEWithoutExpressionReportsError() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("node -e")
        XCTAssertEqual(status.code, 2)
        XCTAssertTrue(cap.stderr.contains("requires an expression"))
    }

    func testNodeWithScriptPath() async throws {
        // The Command path also handles `node script.js` for files
        // without a shebang — covers the case where `node` is invoked
        // explicitly rather than via `./script.js`.
        let dir = NSTemporaryDirectory()
            + "swift-js-cmd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/hello.js"
        try "console.log('hello from file')\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        let (shell, cap) = makeShell()
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let status = try await shell.run("node \(quoted)")
        XCTAssertEqual(status.code, 0)
        XCTAssertEqual(cap.stdout, "hello from file\n")
    }
}
#endif
