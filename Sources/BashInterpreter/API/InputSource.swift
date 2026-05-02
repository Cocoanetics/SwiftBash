import Foundation

/// The byte-oriented stdin made available to a ``Command`` by a ``Shell``.
///
/// Backed by an `AsyncStream<Data>` so pipelines can stream without
/// buffering their whole output. Convenience helpers decode the bytes
/// as UTF-8 text for the common text-oriented commands.
///
/// ```swift
/// // Whole-string consumer (grep / wc / most text commands):
/// let text = await Shell.current.stdin.readAllString()
///
/// // Bytes, for binary-safe commands (cat / sha256 / hexdump):
/// let data = await Shell.current.stdin.readAllData()
///
/// // Line streaming (tail -f / grep -f a stream):
/// for await line in Shell.current.stdin.lines { … }
///
/// // Raw chunk streaming:
/// for await chunk in Shell.current.stdin.bytes { … }
/// ```
public struct InputSource: Sendable {

    public let bytes: AsyncStream<Data>

    /// Stateful read-cursor for `readLine()` / `readBytes(count:)`.
    /// Class-backed so copies of the struct share the iterator —
    /// `while read line; do …; done < file` keeps consuming where
    /// the previous `read` left off.
    private let cursor: ReadCursor

    public init(bytes: AsyncStream<Data>) {
        self.bytes = bytes
        self.cursor = ReadCursor(bytes: bytes)
    }

    /// Read one newline-terminated line from the stream, returning
    /// `nil` at EOF. Subsequent calls continue from where this one
    /// left off. Doesn't conflict with `bytes` / `lines` / `readAllData`
    /// in *practice* — a stream is single-consumer, so a command
    /// should pick *one* style.
    public func readLine() async -> String? {
        await cursor.readLine()
    }

    // MARK: Factories

    /// An already-finished stream with no data.
    public static let empty: InputSource = {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        cont.finish()
        return InputSource(bytes: stream)
    }()

    /// A stream that yields a single UTF-8-encoded chunk then finishes.
    public static func string(_ s: String) -> InputSource {
        .data(Data(s.utf8))
    }

    /// A stream that yields one `Data` chunk then finishes.
    public static func data(_ d: Data) -> InputSource {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        if !d.isEmpty { cont.yield(d) }
        cont.finish()
        return InputSource(bytes: stream)
    }

    // MARK: Consumers

    /// Drain the whole stream into a single `Data`.
    public func readAllData() async -> Data {
        var buf = Data()
        for await chunk in bytes {
            buf.append(chunk)
        }
        return buf
    }

    /// Drain the whole stream and decode as UTF-8, lossily replacing
    /// invalid sequences (matching bash's permissiveness when a text
    /// command is fed binary data).
    public func readAllString() async -> String {
        let data = await readAllData()
        return String(decoding: data, as: UTF8.self)
    }

    /// Stateful single-line reader shared across `InputSource` copies.
    /// Holds a lazy `AsyncIterator` over `bytes` plus a partial-line
    /// buffer so that `read` can pull one line at a time without
    /// losing the rest. Marked `@unchecked Sendable` because shells
    /// are single-threaded — only one command runs `read` at a time.
    final class ReadCursor: @unchecked Sendable {
        private let bytes: AsyncStream<Data>
        private var iterator: AsyncStream<Data>.AsyncIterator?
        private var pending = Data()
        private var atEOF = false

        init(bytes: AsyncStream<Data>) {
            self.bytes = bytes
        }

        func readLine() async -> String? {
            while true {
                if let nl = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<nl]
                    pending.removeSubrange(pending.startIndex..<(nl + 1))
                    return String(decoding: line, as: UTF8.self)
                }
                if atEOF {
                    if pending.isEmpty { return nil }
                    let line = String(decoding: pending, as: UTF8.self)
                    pending.removeAll()
                    return line
                }
                // AsyncStream's iterator is a value type with a
                // `mutating next()`. Lift to a local, advance, write
                // back — `iterator?.next()` would otherwise mutate a
                // temporary copy and lose the position.
                if iterator == nil {
                    iterator = bytes.makeAsyncIterator()
                }
                var it = iterator!
                let chunk = await it.next()
                iterator = it
                if let chunk {
                    pending.append(chunk)
                } else {
                    atEOF = true
                }
            }
        }
    }

    /// Stream the stdin line-by-line. Newlines are stripped; the final
    /// partial line (no trailing newline) is emitted too. Chunks are
    /// re-joined across boundaries so a line that spans multiple
    /// `Data` chunks is delivered intact.
    ///
    /// Cancellation: when the *consumer* of `lines` breaks out of its
    /// for-await loop (e.g., `head -n N` got its N), the AsyncStream's
    /// iterator deinits and our `onTermination` handler cancels the
    /// inner reader Task. That tears down the inner `for await chunk
    /// in bytes` iterator, which in turn fires `OutputSink.onTermination`
    /// upstream — propagating "consumer is gone" all the way back to
    /// the producer's task. Without this hop the inner task would keep
    /// pulling bytes into an invalidated continuation forever, and the
    /// producer would never see SIGPIPE-equivalent.
    public var lines: AsyncStream<String> {
        let upstream = bytes
        return AsyncStream<String> { continuation in
            let reader = Task {
                var pending = ""
                for await chunk in upstream {
                    if Task.isCancelled { break }
                    pending += String(decoding: chunk, as: UTF8.self)
                    while let nlRange = pending.range(of: "\n") {
                        let line = String(pending[..<nlRange.lowerBound])
                        pending.removeSubrange(pending.startIndex..<nlRange.upperBound)
                        continuation.yield(line)
                    }
                }
                if !pending.isEmpty {
                    continuation.yield(pending)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}
