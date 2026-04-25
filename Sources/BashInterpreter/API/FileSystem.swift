import Foundation

/// A sandboxed filesystem a ``Shell`` reads and writes through. All
/// file-touching commands (`cat`, `ls`, `mkdir`, `cd`, `realpath`, …)
/// route calls here instead of to `FileManager` directly, so the same
/// bash script can run against a real directory, an in-memory store,
/// a zip archive, or anything else that conforms.
///
/// Paths are passed as byte-oriented `String`s to match bash's semantics.
/// Callers are expected to hand in *absolute* paths — relative paths
/// are resolved against `Shell.environment.workingDirectory` first via
/// ``Shell/resolvePath(_:)``.
public protocol FileSystem: Sendable {

    // MARK: Inspection

    /// Metadata for `path`, or `nil` if nothing exists there.
    func metadata(_ path: String) async throws -> FileMetadata?

    /// Directory entry names (not full paths), unsorted. Throws if
    /// `path` isn't a directory.
    func list(_ path: String) async throws -> [String]

    /// Canonical absolute path with symlinks resolved and `.` / `..`
    /// normalised. If `allowMissing` is false, throws
    /// ``FileSystemError/notFound(_:)`` when the path doesn't exist.
    func canonicalize(_ path: String, allowMissing: Bool) async throws -> String

    // MARK: Reading

    /// Read the entire contents of `path`.
    func readData(_ path: String) async throws -> Data

    /// Open `path` as a streaming byte source. The default reads the
    /// whole file into memory via ``readData(_:)``; concrete file systems
    /// can override for true streaming.
    func openRead(_ path: String) async throws -> InputSource

    // MARK: Writing

    /// Write `data` to `path`, creating or truncating. Passing
    /// `append: true` appends instead.
    func writeData(_ data: Data, to path: String, append: Bool) async throws

    /// Open `path` for writing as a streaming byte sink. Truncates
    /// unless `append: true`. Bytes written to the returned
    /// ``OutputSink`` flush to disk as they arrive; ``OutputSink/finish()``
    /// closes the underlying handle. Used by `>` / `>>` redirection.
    func openWrite(_ path: String, append: Bool) async throws -> OutputSink

    /// Create an empty file at `path`, or update its modification time
    /// if it already exists.
    func touch(_ path: String) async throws

    // MARK: Directories

    /// Create a directory at `path`. If `intermediates` is true,
    /// missing parent directories are created too (like `mkdir -p`).
    func createDirectory(_ path: String, intermediates: Bool) async throws

    // MARK: Removal / move / copy

    /// Remove the file or directory at `path`. Directories require
    /// `recursive: true`.
    func remove(_ path: String, recursive: Bool) async throws

    /// Move / rename `from` to `to`.
    func move(from: String, to: String) async throws

    /// Copy `from` to `to`. Directory copies are recursive.
    func copy(from: String, to: String) async throws

    /// Allocate a unique path under a temp directory inside this file
    /// system, suitable for short-lived files like process-substitution
    /// buffers. Default places it under `/tmp/swift-bash/<prefix>-uuid`;
    /// real-disk implementations override to use `NSTemporaryDirectory`.
    func makeTempPath(prefix: String) async throws -> String
}

public extension FileSystem {
    func openRead(_ path: String) async throws -> InputSource {
        let data = try await readData(path)
        return .data(data)
    }

    /// Default buffer-and-flush implementation for file systems that
    /// don't support true streaming writes. Accumulates every written
    /// chunk and calls ``writeData(_:to:append:)`` once on
    /// ``OutputSink/finish()``.
    func openWrite(_ path: String, append: Bool) async throws -> OutputSink {
        let buffer = FileSystemWriteBuffer()
        // Truncate upfront when append == false so the file reflects an
        // in-progress write even if finish() is never called.
        if !append {
            try await writeData(Data(), to: path, append: false)
        }
        let fsRef: any FileSystem = self
        return OutputSink(
            bufferingPolicy: .bufferingOldest(0),
            onWrite: { data in buffer.append(data) },
            onFinish: {
                let data = buffer.drain()
                guard !data.isEmpty || append == false else { return }
                // Fire-and-forget: file systems using this fallback
                // don't expose per-chunk streaming anyway.
                let toAppend: Data = data
                Task.detached {
                    try? await fsRef.writeData(toAppend, to: path,
                                               append: true)
                }
            })
    }

    func canonicalize(_ path: String) async throws -> String {
        try await canonicalize(path, allowMissing: false)
    }

    func makeTempPath(prefix: String) async throws -> String {
        let dir = "/tmp/swift-bash"
        try? await createDirectory(dir, intermediates: true)
        return "\(dir)/\(prefix)-\(UUID().uuidString)"
    }
}

/// Thread-safe buffer used by the default `openWrite` fallback.
final class FileSystemWriteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }
    func drain() -> Data {
        lock.lock(); defer { lock.unlock() }
        let d = data; data = Data(); return d
    }
}

// MARK: Metadata

public struct FileMetadata: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file, directory, symlink, other
    }

    public let kind: Kind
    public let size: Int64
    public let modifiedAt: Date
    /// For symlinks, the raw target string; `nil` otherwise.
    public let symlinkTarget: String?

    public init(kind: Kind,
                size: Int64,
                modifiedAt: Date,
                symlinkTarget: String? = nil) {
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.symlinkTarget = symlinkTarget
    }
}

// MARK: Errors

public enum FileSystemError: Error, CustomStringConvertible, Sendable, Equatable {
    case notFound(String)
    case notADirectory(String)
    case isADirectory(String)
    case alreadyExists(String)
    case permissionDenied(String)
    case io(String)

    public var description: String {
        switch self {
        case .notFound(let p):         return "no such file or directory: \(p)"
        case .notADirectory(let p):    return "not a directory: \(p)"
        case .isADirectory(let p):     return "is a directory: \(p)"
        case .alreadyExists(let p):    return "already exists: \(p)"
        case .permissionDenied(let p): return "permission denied: \(p)"
        case .io(let m):               return m
        }
    }
}
