import Foundation

/// The byte-oriented stdout / stderr a ``Shell`` hands to its commands.
///
/// An `OutputSink` is bash's fd1/fd2 modelled as a stream: every write
/// is synchronous (commands don't have to `await`), and an
/// `AsyncStream<Data>` is exposed for callers who want to consume the
/// output as it's produced.
///
/// ```swift
/// // Inside a command:
/// Shell.current.stdout("hello\n")           // String convenience
/// Shell.current.stdout(Data([0x00, 0xFF]))  // binary-safe
///
/// // Outside, consume as a stream:
/// for await chunk in Shell.current.stdout.bytes { … }
///
/// // Or drain the whole thing once you know the producer is done:
/// Shell.current.stdout.finish()
/// let text = await Shell.current.stdout.readAllString()
/// ```
///
/// The `onWrite` hook is called synchronously on every write in
/// addition to the stream being fed. That's how the default
/// `forwarding(to:)` sink ships bytes straight to a file handle (fd 1
/// or fd 2) with no task switching — keeping `tail -f`-style
/// consumers live.
public final class OutputSink: @unchecked Sendable {

    /// The underlying stream of byte chunks. Consume it once — iterating
    /// a second time will yield nothing.
    public let bytes: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let onWrite: @Sendable (Data) -> Void
    private let onFinish: @Sendable () -> Void

    public init(
        bufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy = .unbounded,
        onWrite: @escaping @Sendable (Data) -> Void = { _ in },
        onFinish: @escaping @Sendable () -> Void = {}
    ) {
        let (stream, cont) = AsyncStream<Data>.makeStream(
            bufferingPolicy: bufferingPolicy)
        self.bytes = stream
        self.continuation = cont
        self.onWrite = onWrite
        self.onFinish = onFinish
    }

    // MARK: Writing (from commands)

    public func write(_ data: Data) {
        onWrite(data)
        continuation.yield(data)
    }

    public func write(_ text: String) {
        write(Data(text.utf8))
    }

    /// Terse form — `Shell.current.stdout("hi\n")`.
    public func callAsFunction(_ data: Data) { write(data) }
    public func callAsFunction(_ text: String) { write(text) }

    /// Close the output stream. After this, consumers iterating `bytes`
    /// (or reading via `readAllData` / `readAllString` / `lines`) will
    /// see the iterator finish, and the `onFinish` hook fires — which
    /// file-backed sinks use to close their handle.
    public func finish() {
        continuation.finish()
        onFinish()
    }

    // MARK: Reading (from outside)

    /// Drain the whole stream into a single `Data`. Blocks until
    /// ``finish()`` is called on the writing side.
    public func readAllData() async -> Data {
        var buf = Data()
        for await chunk in bytes { buf.append(chunk) }
        return buf
    }

    /// UTF-8 decode of the drained stream, lossily replacing invalid
    /// sequences.
    public func readAllString() async -> String {
        String(decoding: await readAllData(), as: UTF8.self)
    }

    /// Line-by-line iteration — joins chunks across buffer boundaries
    /// and strips the trailing `\n`.
    public var lines: AsyncStream<String> {
        AsyncStream<String> { continuation in
            Task {
                var pending = ""
                for await chunk in bytes {
                    pending += String(decoding: chunk, as: UTF8.self)
                    while let nl = pending.range(of: "\n") {
                        let line = String(pending[..<nl.lowerBound])
                        pending.removeSubrange(pending.startIndex..<nl.upperBound)
                        continuation.yield(line)
                    }
                }
                if !pending.isEmpty { continuation.yield(pending) }
                continuation.finish()
            }
        }
    }

    // MARK: Factories

    /// Forward every write straight to `fileHandle` (typically
    /// `FileHandle.standardOutput` or `.standardError`). The stream
    /// still exists but uses `.bufferingOldest(0)` so it doesn't
    /// retain bytes the writer would never read back.
    public static func forwarding(to fileHandle: FileHandle) -> OutputSink {
        OutputSink(bufferingPolicy: .bufferingOldest(0)) { data in
            fileHandle.write(data)
        }
    }

    /// A sink that drops everything written (both stream and hook).
    public static var discard: OutputSink {
        OutputSink(bufferingPolicy: .bufferingOldest(0))
    }

    /// A sink whose writes forward to `upstream` and whose `finish()` is
    /// a deliberate no-op on the upstream — used for redirections to
    /// `/dev/stdout` / `/dev/stderr` so that closing the redirection
    /// doesn't close the shell's actual fd1/fd2.
    public static func proxy(to upstream: OutputSink) -> OutputSink {
        OutputSink(
            bufferingPolicy: .bufferingOldest(0),
            onWrite: { upstream.write($0) },
            onFinish: { /* deliberately do not close upstream */ })
    }
}
