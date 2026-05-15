import Foundation
@testable import BashInterpreter

/// Shadow `Testing.ExitStatus` — the Swift Testing 1743+ exit-test API
/// exports a type of the same name, and these tests predate it.
typealias ExitStatus = BashInterpreter.ExitStatus

/// A test helper wiring a Shell up to in-memory buffers. Bytes written
/// by `Shell.bashCurrent.stdout(_:)` / `Shell.bashCurrent.stderr(_:)` are UTF-8 decoded and
/// appended to the `stdout` / `stderr` strings on this instance —
/// the common case for assertion. The underlying `OutputSink`s still
/// expose `.bytes` streams if a test needs to consume output live.
final class CapturingShell: @unchecked Sendable {
    let shell: Shell

    private final class StringBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ data: Data) {
            // Test capture: stdout bytes may be arbitrary; tolerate non-UTF-8.
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
    private let _stdout = StringBox()
    private let _stderr = StringBox()

    var stdout: String { _stdout.read() }
    var stderr: String { _stderr.read() }

    init(environment: Environment = Environment()) {
        let stdoutSink = OutputSink(onWrite: { [weak _stdout] data in
            _stdout?.append(data)
        })
        let stderrSink = OutputSink(onWrite: { [weak _stderr] data in
            _stderr?.append(data)
        })
        self.shell = Shell(environment: environment,
                           stdout: stdoutSink,
                           stderr: stderrSink)
    }
}
