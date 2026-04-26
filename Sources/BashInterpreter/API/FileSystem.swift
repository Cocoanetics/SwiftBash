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

    // MARK: Permissions / ownership

    /// Set the POSIX permission bits on `path`.
    func chmod(_ path: String, mode: UInt16) async throws

    /// Set the owner uid / gid on `path`. Pass `nil` to leave a value
    /// unchanged.
    func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws

    // MARK: Links

    /// Create a symbolic link at `linkPath` whose target is `target`.
    /// `target` is stored verbatim — no canonicalisation.
    func symlink(target: String, at linkPath: String) async throws

    /// Create a hard link at `linkPath` pointing at the same inode as
    /// `target`. In-memory file systems may emulate via deep copy.
    func hardlink(target: String, at linkPath: String) async throws

    // MARK: Extended attributes

    /// List the names of extended attributes on `path`.
    func listXattrs(_ path: String) async throws -> [String]

    /// Read the value of one extended attribute. Throws if missing.
    func getXattr(_ path: String, name: String) async throws -> Data

    /// Write or replace one extended attribute.
    func setXattr(_ path: String, name: String, value: Data) async throws

    /// Remove one extended attribute. Silently succeeds if absent.
    func removeXattr(_ path: String, name: String) async throws
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

    // MARK: Default no-op-ish implementations for the new operations.
    //
    // Backings that don't natively track permissions / xattrs can still
    // satisfy the protocol: chmod/chown become no-ops, link operations
    // throw a clear error, and xattr methods report no attributes.

    func chmod(_ path: String, mode: UInt16) async throws {
        guard try await metadata(path) != nil else {
            throw FileSystemError.notFound(path)
        }
        // Default: nothing to record. RealFileSystem and
        // InMemoryFileSystem override this.
    }

    func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        guard try await metadata(path) != nil else {
            throw FileSystemError.notFound(path)
        }
    }

    func symlink(target: String, at linkPath: String) async throws {
        throw FileSystemError.io("symlink not supported by this file system")
    }

    func hardlink(target: String, at linkPath: String) async throws {
        // Fall back to copy. Real fs / in-memory override.
        try await copy(from: target, to: linkPath)
    }

    func listXattrs(_ path: String) async throws -> [String] {
        guard try await metadata(path) != nil else {
            throw FileSystemError.notFound(path)
        }
        return []
    }

    func getXattr(_ path: String, name: String) async throws -> Data {
        throw FileSystemError.io("no such xattr: \(name)")
    }

    func setXattr(_ path: String, name: String, value: Data) async throws {
        throw FileSystemError.io("setXattr not supported by this file system")
    }

    func removeXattr(_ path: String, name: String) async throws {
        // Silent no-op when xattrs aren't supported.
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
    /// POSIX permission bits (the low 12 bits include sticky / setuid).
    public let mode: UInt16
    /// Owner user ID. Real fs reports the host's value; in-memory fs
    /// defaults to the current process's uid.
    public let uid: UInt32
    /// Owner group ID.
    public let gid: UInt32
    /// Hard-link count (1 unless explicitly linked).
    public let linkCount: Int
    /// Last access time. Defaults to `modifiedAt` when the backing
    /// store doesn't track it separately.
    public let accessedAt: Date
    /// Inode change / creation time, depending on platform.
    public let createdAt: Date

    public init(kind: Kind,
                size: Int64,
                modifiedAt: Date,
                symlinkTarget: String? = nil,
                mode: UInt16 = 0o644,
                uid: UInt32 = 0,
                gid: UInt32 = 0,
                linkCount: Int = 1,
                accessedAt: Date? = nil,
                createdAt: Date? = nil) {
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.symlinkTarget = symlinkTarget
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.linkCount = linkCount
        self.accessedAt = accessedAt ?? modifiedAt
        self.createdAt = createdAt ?? modifiedAt
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
