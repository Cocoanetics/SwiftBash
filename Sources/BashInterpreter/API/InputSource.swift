import Foundation

/// The byte-oriented stdin made available to a ``Command`` by a ``Shell``.
///
/// Backed by an `AsyncStream<Data>` so pipelines can stream without
/// buffering their whole output. Convenience helpers decode the bytes
/// as UTF-8 text for the common text-oriented commands.
///
/// ```swift
/// // Whole-string consumer (grep / wc / most text commands):
/// let text = await shell.stdin.readAllString()
///
/// // Bytes, for binary-safe commands (cat / sha256 / hexdump):
/// let data = await shell.stdin.readAllData()
///
/// // Line streaming (tail -f / grep -f a stream):
/// for await line in shell.stdin.lines { … }
///
/// // Raw chunk streaming:
/// for await chunk in shell.stdin.bytes { … }
/// ```
public struct InputSource: Sendable {

    public let bytes: AsyncStream<Data>

    public init(bytes: AsyncStream<Data>) {
        self.bytes = bytes
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

    /// Stream the stdin line-by-line. Newlines are stripped; the final
    /// partial line (no trailing newline) is emitted too. Chunks are
    /// re-joined across boundaries so a line that spans multiple
    /// `Data` chunks is delivered intact.
    public var lines: AsyncStream<String> {
        AsyncStream<String> { continuation in
            Task {
                var pending = ""
                for await chunk in bytes {
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
        }
    }
}
