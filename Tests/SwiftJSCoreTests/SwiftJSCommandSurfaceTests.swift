#if canImport(JavaScriptCore)
import Testing
import Foundation
import ShellKit
@testable import SwiftJSCore
@testable import BashInterpreter
import BashCommandKit

/// Issue #37: in-process `node` / `bun` / `swift-js` must accept the
/// same argv shape as the standalone CLI — `--version`, `-e <expr>`,
/// `-p <expr>`, and `<script.js>`. Before the fix these only worked
/// via the script-interpreter (shebang) path, so a bare
/// `node --version` invocation failed.
///
/// Uses Swift Testing rather than XCTest because mixing JSC + XCTest
/// + bash pipeline dispatch crashes swift-corelibs-xctest's signal
/// handler on Linux during teardown; the Swift Testing path is
/// unaffected.
@Suite(.timeLimit(.minutes(1))) struct SwiftJSCommandSurfaceTests {

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

    private func makeShell() -> (BashInterpreter.Shell, Capture) {
        let cap = Capture()
        let shell = BashInterpreter.Shell(
            stdout: cap.stdoutSink,
            stderr: cap.stderrSink,
            environment: Environment())
        shell.registerSwiftJS()
        return (shell, cap)
    }

    private static func bashQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @Test func nodeVersionFlag() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("node --version")
        #expect(status.code == 0)
        #expect(cap.stdout.contains("v22"))
    }

    @Test func bunVersionFlag() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("bun --version")
        #expect(status.code == 0)
        #expect(!cap.stdout.isEmpty)
    }

    @Test func swiftJsVersionFlag() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("swift-js --version")
        #expect(status.code == 0)
        #expect(cap.stdout.contains("swift-js"))
    }

    @Test func nodeDashE() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("node -e 'console.log(2 + 3)'")
        #expect(status.code == 0)
        #expect(cap.stdout == "5\n")
    }

    @Test func nodeDashPPrintsExpression() async throws {
        let (shell, cap) = makeShell()
        // `-p` evaluates and prints the resulting expression value.
        let status = try await shell.run("node -p '40 + 2'")
        #expect(status.code == 0)
        #expect(cap.stdout == "42\n")
    }

    @Test func bunDashE() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("bun -e 'console.log(\"hi\")'")
        #expect(status.code == 0)
        #expect(cap.stdout == "hi\n")
    }

    @Test func nodeDashEWithoutExpressionReportsError() async throws {
        let (shell, cap) = makeShell()
        let status = try await shell.run("node -e")
        #expect(status.code == 2)
        #expect(cap.stderr.contains("requires an expression"))
    }

    @Test func nodeResolvesRelativePathAgainstShellCwd() async throws {
        // Regression for codex P1 review: `node foo.js` after an
        // in-shell `cd` must resolve against the shell's working
        // directory, not the host process cwd.
        let dir = NSTemporaryDirectory()
            + "swift-js-relcwd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/rel.js"
        try "console.log('from cwd')\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        let (shell, cap) = makeShell()
        let status = try await shell.run(
            "cd \(Self.bashQuote(dir)) && node rel.js")
        #expect(status.code == 0)
        #expect(cap.stdout == "from cwd\n")
    }

    @Test func nodeWithScriptPath() async throws {
        let dir = NSTemporaryDirectory()
            + "swift-js-cmd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/hello.js"
        try "console.log('hello from file')\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        let (shell, cap) = makeShell()
        let status = try await shell.run("node \(Self.bashQuote(path))")
        #expect(status.code == 0)
        #expect(cap.stdout == "hello from file\n")
    }
}
#endif
