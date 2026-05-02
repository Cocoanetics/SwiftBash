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

    /// Set by the AsyncStream's continuation `onTermination` callback —
    /// fires when the read side's iterator deinits (consumer broke out
    /// of `for await … in bytes`) or when ``finish()`` is called. The
    /// pipeline assigns ``onConsumerGone`` so a producer that's still
    /// busy gets `Task.cancel`'d instead of writing into the void
    /// forever. Plain `Atomic`-style guarded access — single writer
    /// (the continuation handler) and at most one reader (the
    /// pipeline's hookup site).
    private let stateLock = NSLock()
    private var _terminated: Bool = false
    private var _onConsumerGone: (@Sendable () -> Void)?

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
        // Wire the AsyncStream's termination signal — fired both when
        // the writer calls `finish()` and when the read iterator dies
        // (e.g., `for await line in bytes { …; if … { break } }`). We
        // care about the second case for pipe-cancellation: the bash
        // semantics is "downstream went away ⇒ producer gets SIGPIPE".
        // We approximate that by cancelling the producer's task, which
        // lets the wrapping pipeline runner observe it cleanly.
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            self._terminated = true
            let hook = self._onConsumerGone
            self.stateLock.unlock()
            hook?()
        }
    }

    /// True once the read side has gone away or `finish()` has been
    /// called. Producers that synthesize their own data without going
    /// through `Shell.current.stdout(...)` can poll this to avoid
    /// generating garbage.
    public var isTerminated: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _terminated
    }

    /// Install a one-shot hook that fires when the read side terminates
    /// (typically used by the pipeline runner to cancel the producer
    /// task). If termination has *already* fired, the hook runs
    /// immediately so registration order doesn't matter.
    public func setOnConsumerGone(_ handler: @escaping @Sendable () -> Void) {
        stateLock.lock()
        if _terminated {
            stateLock.unlock()
            handler()
            return
        }
        _onConsumerGone = handler
        stateLock.unlock()
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
    /// and strips the trailing `\n`. Same cancellation propagation as
    /// `InputSource.lines`: terminating the outer iterator cancels the
    /// inner reader so the upstream bytes iteration tears down too.
    public var lines: AsyncStream<String> {
        let upstream = bytes
        return AsyncStream<String> { continuation in
            let reader = Task {
                var pending = ""
                for await chunk in upstream {
                    if Task.isCancelled { break }
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
            continuation.onTermination = { _ in reader.cancel() }
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
