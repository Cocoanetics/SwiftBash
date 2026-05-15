import Foundation
@testable import BashInterpreter

/// Shadow `Testing.ExitStatus` — the Swift Testing 1743+ exit-test API
/// exports a type of the same name, and these tests predate it.
typealias ExitStatus = BashInterpreter.ExitStatus

/// Captures stdout/stderr written by a shell for assertion. Bytes are
/// UTF-8 decoded into the `stdout` / `stderr` strings.
final class CapturingShell: @unchecked Sendable {
    let shell: Shell

    private final class StringBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ data: Data) {
            // Bash output may include arbitrary bytes (binary cat,
            // partial UTF-8 chunks). Lossy decode is intentional here.
            // swiftlint:disable:next optional_data_string_conversion
            let chunk = String(decoding: data, as: UTF8.self)
            lock.lock(); defer { lock.unlock() }
            value.append(chunk)
        }
        func read() -> String {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    private let _stdout = StringBox()
    private let _stderr = StringBox()

    var stdout: String { _stdout.read() }
    var stderr: String { _stderr.read() }

    init() {
        let stdoutSink = OutputSink(onWrite: { [weak _stdout] data in
            _stdout?.append(data)
        })
        let stderrSink = OutputSink(onWrite: { [weak _stderr] data in
            _stderr?.append(data)
        })
        self.shell = Shell(stdout: stdoutSink, stderr: stderrSink)
    }
}
