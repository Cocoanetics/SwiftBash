import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A ``FileSystem`` backed by the host process's real filesystem via
/// `FileManager`. All operations use absolute paths — relative paths
/// must be resolved against ``Shell/resolvePath(_:)`` by the caller.
///
/// No sandboxing is applied: every path is passed straight through. Use
/// this on a trusted workstation; for untrusted scripts, write a
/// chroot-style wrapper that rejects paths outside a root prefix.
public struct RealFileSystem: FileSystem {

    public init() {}

    private var fm: FileManager { FileManager.default }

    // MARK: Inspection

    /// Follows symlinks — a symlink pointing at a directory reports
    /// `kind == .directory`. Returns `nil` if the path (or a broken
    /// symlink's target) doesn't exist.
    public func metadata(_ path: String) async throws -> FileMetadata? {
        var st = stat()
        if stat(path, &st) != 0 { return nil }
        return FileMetadata.fromStat(st)
    }

    public func list(_ path: String) async throws -> [String] {
        do {
            return try fm.contentsOfDirectory(atPath: path)
        } catch let e as NSError where e.code == NSFileReadNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let e as NSError where e.code == NSFileReadUnknownError
                                    || e.code == 256 {
            throw FileSystemError.notADirectory(path)
        }
    }

    public func canonicalize(_ path: String,
                             allowMissing: Bool) async throws -> String {
        let url = URL(fileURLWithPath: path)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
        let resolved = url.path
        if !allowMissing, !fm.fileExists(atPath: resolved) {
            throw FileSystemError.notFound(path)
        }
        return resolved
    }

    // MARK: Reading

    public func readData(_ path: String) async throws -> Data {
        let url = URL(fileURLWithPath: path)
        do {
            return try Data(contentsOf: url)
        } catch let e as NSError where e.code == NSFileReadNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let e as NSError where e.code == NSFileReadInapplicableStringEncodingError {
            throw FileSystemError.isADirectory(path)
        } catch let e as NSError where e.code == NSFileReadNoPermissionError {
            throw FileSystemError.permissionDenied(path)
        }
    }

    public func openRead(_ path: String) async throws -> InputSource {
        // True streaming: feed 64 KB chunks into an AsyncStream from a
        // background read on a FileHandle.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch let e as NSError where e.code == NSFileReadNoSuchFileError
                                    || e.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let e as NSError where e.code == NSFileReadNoPermissionError {
            throw FileSystemError.permissionDenied(path)
        }

        let stream = AsyncStream<Data> { continuation in
            Task.detached {
                let chunkSize = 64 * 1024
                while !Task.isCancelled {
                    let chunk = handle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    continuation.yield(chunk)
                }
                try? handle.close()
                continuation.finish()
            }
        }
        return InputSource(bytes: stream)
    }

    // MARK: Writing

    public func writeData(_ data: Data, to path: String, append: Bool) async throws {
        let url = URL(fileURLWithPath: path)
        if !append {
            do {
                try data.write(to: url)
                return
            } catch let e as NSError where e.code == NSFileWriteNoPermissionError {
                throw FileSystemError.permissionDenied(path)
            } catch let e as NSError where e.code == NSFileWriteFileExistsError {
                throw FileSystemError.alreadyExists(path)
            } catch {
                throw FileSystemError.io(
                    "write to \(path) failed: \(error.localizedDescription)")
            }
        }
        // Append mode.
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw FileSystemError.io(
                "open \(path) for append failed: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func openWrite(_ path: String, append: Bool) async throws -> OutputSink {
        // Prime the file (creates parent? no — caller's job) and open
        // a FileHandle for streaming writes.
        let url = URL(fileURLWithPath: path)
        if append {
            if !fm.fileExists(atPath: path) {
                if !fm.createFile(atPath: path, contents: nil) {
                    throw FileSystemError.io("could not create \(path)")
                }
            }
        } else {
            // Truncate by writing zero bytes.
            do {
                try Data().write(to: url)
            } catch let e as NSError where e.code == NSFileWriteNoPermissionError {
                throw FileSystemError.permissionDenied(path)
            } catch {
                throw FileSystemError.io(
                    "open \(path) for write failed: \(error.localizedDescription)")
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw FileSystemError.io(
                "open \(path) for write failed: \(error.localizedDescription)")
        }
        if append { try? handle.seekToEnd() }

        let handleBox = FileHandleBox(handle: handle)
        return OutputSink(
            bufferingPolicy: .bufferingOldest(0),
            onWrite: { [handleBox] data in handleBox.write(data) },
            onFinish: { [handleBox] in handleBox.close() })
    }

    public func makeTempPath(prefix: String) async throws -> String {
        let dir = NSTemporaryDirectory() + "swift-bash"
        try? await createDirectory(dir, intermediates: true)
        return "\(dir)/\(prefix)-\(UUID().uuidString)"
    }

    public func touch(_ path: String) async throws {
        if !fm.fileExists(atPath: path) {
            if !fm.createFile(atPath: path, contents: Data()) {
                throw FileSystemError.io("could not create \(path)")
            }
            return
        }
        // Update mtime to now.
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }

    // MARK: Directories

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws {
        do {
            try fm.createDirectory(
                atPath: path,
                withIntermediateDirectories: intermediates)
        } catch let e as NSError where e.code == NSFileWriteFileExistsError {
            throw FileSystemError.alreadyExists(path)
        } catch let e as NSError where e.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let e as NSError where e.code == NSFileWriteNoPermissionError {
            throw FileSystemError.permissionDenied(path)
        } catch {
            throw FileSystemError.io(
                "mkdir \(path) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Removal / move / copy

    public func remove(_ path: String, recursive: Bool) async throws {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(path)
        }
        if isDir.boolValue && !recursive {
            // Match POSIX `rmdir` semantics: only remove if empty.
            let entries = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            if !entries.isEmpty {
                throw FileSystemError.isADirectory(path)
            }
        }
        do {
            try fm.removeItem(atPath: path)
        } catch let e as NSError where e.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let e as NSError where e.code == NSFileWriteNoPermissionError {
            throw FileSystemError.permissionDenied(path)
        }
    }

    public func move(from: String, to: String) async throws {
        do {
            try fm.moveItem(atPath: from, toPath: to)
        } catch let e as NSError where e.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(from)
        } catch let e as NSError where e.code == NSFileWriteFileExistsError {
            throw FileSystemError.alreadyExists(to)
        } catch {
            throw FileSystemError.io(
                "mv \(from) \(to) failed: \(error.localizedDescription)")
        }
    }

    public func copy(from: String, to: String) async throws {
        do {
            try fm.copyItem(atPath: from, toPath: to)
        } catch let e as NSError where e.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(from)
        } catch let e as NSError where e.code == NSFileWriteFileExistsError {
            throw FileSystemError.alreadyExists(to)
        } catch {
            throw FileSystemError.io(
                "cp \(from) \(to) failed: \(error.localizedDescription)")
        }
    }
}

// MARK: Helpers

/// Thread-safe wrapper around a `FileHandle` so ``RealFileSystem``'s
/// streaming write sinks stay `@Sendable`. Writes serialise through the
/// internal lock; `close()` is idempotent.
final class FileHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(handle: FileHandle) { self.handle = handle }

    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        try? handle?.write(contentsOf: data)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}

private extension FileMetadata {
    static func fromStat(_ s: stat) -> FileMetadata {
        let kind: Kind
        let mode = s.st_mode
        if (mode & S_IFMT) == S_IFLNK       { kind = .symlink }
        else if (mode & S_IFMT) == S_IFDIR  { kind = .directory }
        else if (mode & S_IFMT) == S_IFREG  { kind = .file }
        else                                { kind = .other }

        let mtime = Date(timeIntervalSince1970:
                            TimeInterval(s.st_mtimespec.tv_sec))
        return FileMetadata(kind: kind,
                            size: Int64(s.st_size),
                            modifiedAt: mtime)
    }
}
