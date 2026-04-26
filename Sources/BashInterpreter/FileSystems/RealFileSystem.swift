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
        // lstat first to detect symlinks and capture their target.
        var lst = stat()
        let lstatOK = path.withCString { lstat($0, &lst) } == 0

        var symlinkTarget: String? = nil
        if lstatOK, (lst.st_mode & S_IFMT) == S_IFLNK {
            var buf = [Int8](repeating: 0, count: 4096)
            let n = path.withCString { p in
                buf.withUnsafeMutableBufferPointer { bp in
                    Darwin.readlink(p, bp.baseAddress, bp.count)
                }
            }
            if n > 0 {
                let bytes = (0..<Int(n)).map { UInt8(bitPattern: buf[$0]) }
                symlinkTarget = String(decoding: bytes, as: UTF8.self)
            }
        }

        // Now follow symlinks for kind/size/mode etc. We use
        // `fstatat(AT_FDCWD, path, &st, 0)` because the `stat` symbol
        // alone is ambiguous in Swift (the struct shadows the function).
        var st = stat()
        let statOK = path.withCString { fstatat(AT_FDCWD, $0, &st, 0) } == 0
        if !statOK {
            // Broken symlink → return lstat info so callers can still see
            // the link target. Otherwise the path simply doesn't exist.
            if lstatOK { return FileMetadata.fromStat(lst, symlinkTarget: symlinkTarget) }
            return nil
        }
        return FileMetadata.fromStat(st, symlinkTarget: symlinkTarget)
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
        if append { _ = try? handle.seekToEnd() }

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
    static func fromStat(_ s: stat, symlinkTarget: String? = nil) -> FileMetadata {
        let kind: Kind
        let rawMode = s.st_mode
        if (rawMode & S_IFMT) == S_IFLNK       { kind = .symlink }
        else if (rawMode & S_IFMT) == S_IFDIR  { kind = .directory }
        else if (rawMode & S_IFMT) == S_IFREG  { kind = .file }
        else                                   { kind = .other }

        let mtime = Date(timeIntervalSince1970: TimeInterval(s.st_mtimespec.tv_sec))
        let atime = Date(timeIntervalSince1970: TimeInterval(s.st_atimespec.tv_sec))
        let ctime = Date(timeIntervalSince1970: TimeInterval(s.st_ctimespec.tv_sec))
        return FileMetadata(kind: kind,
                            size: Int64(s.st_size),
                            modifiedAt: mtime,
                            symlinkTarget: symlinkTarget,
                            mode: UInt16(rawMode & 0o7777),
                            uid: UInt32(s.st_uid),
                            gid: UInt32(s.st_gid),
                            linkCount: Int(s.st_nlink),
                            accessedAt: atime,
                            createdAt: ctime)
    }
}

// MARK: - Permissions / links / xattrs

public extension RealFileSystem {

    func chmod(_ path: String, mode: UInt16) async throws {
        let r = path.withCString { Darwin.chmod($0, mode_t(mode)) }
        if r != 0 { throw fsError(op: "chmod", path: path) }
    }

    func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        // -1 means "leave unchanged" in chown(2).
        let u = uid.map { uid_t($0) } ?? uid_t(bitPattern: -1)
        let g = gid.map { gid_t($0) } ?? gid_t(bitPattern: -1)
        let r = path.withCString { Darwin.chown($0, u, g) }
        if r != 0 { throw fsError(op: "chown", path: path) }
    }

    func symlink(target: String, at linkPath: String) async throws {
        let r = target.withCString { tp in
            linkPath.withCString { lp in
                Darwin.symlink(tp, lp)
            }
        }
        if r != 0 { throw fsError(op: "symlink", path: linkPath) }
    }

    func hardlink(target: String, at linkPath: String) async throws {
        let r = target.withCString { tp in
            linkPath.withCString { lp in
                Darwin.link(tp, lp)
            }
        }
        if r != 0 { throw fsError(op: "link", path: linkPath) }
    }

    func listXattrs(_ path: String) async throws -> [String] {
        let needed = path.withCString { listxattr($0, nil, 0, 0) }
        if needed < 0 { throw fsError(op: "listxattr", path: path) }
        if needed == 0 { return [] }
        var buf = [Int8](repeating: 0, count: needed)
        let written = path.withCString { p in
            buf.withUnsafeMutableBufferPointer { bp in
                listxattr(p, bp.baseAddress, needed, 0)
            }
        }
        if written < 0 { throw fsError(op: "listxattr", path: path) }
        var names: [String] = []
        var i = 0
        while i < written {
            let start = i
            while i < written, buf[i] != 0 { i += 1 }
            if i > start {
                let bytes = (start..<i).map { UInt8(bitPattern: buf[$0]) }
                names.append(String(decoding: bytes, as: UTF8.self))
            }
            i += 1
        }
        return names
    }

    func getXattr(_ path: String, name: String) async throws -> Data {
        let needed = path.withCString { p in
            name.withCString { n in getxattr(p, n, nil, 0, 0, 0) }
        }
        if needed < 0 { throw fsError(op: "getxattr", path: path) }
        if needed == 0 { return Data() }
        var buf = [UInt8](repeating: 0, count: needed)
        let written = path.withCString { p in
            name.withCString { n in
                buf.withUnsafeMutableBufferPointer { bp in
                    getxattr(p, n, bp.baseAddress, needed, 0, 0)
                }
            }
        }
        if written < 0 { throw fsError(op: "getxattr", path: path) }
        return Data(buf.prefix(written))
    }

    func setXattr(_ path: String, name: String, value: Data) async throws {
        let r = path.withCString { p in
            name.withCString { n in
                value.withUnsafeBytes { vb in
                    setxattr(p, n, vb.baseAddress, value.count, 0, 0)
                }
            }
        }
        if r < 0 { throw fsError(op: "setxattr", path: path) }
    }

    func removeXattr(_ path: String, name: String) async throws {
        let r = path.withCString { p in
            name.withCString { n in removexattr(p, n, 0) }
        }
        // ENOATTR (93 on macOS) is fine — silent no-op.
        if r < 0 && errno != 93 {
            throw fsError(op: "removexattr", path: path)
        }
    }
}

private func fsError(op: String, path: String) -> FileSystemError {
    let msg = String(cString: strerror(errno))
    if errno == ENOENT { return .notFound(path) }
    if errno == EACCES || errno == EPERM { return .permissionDenied(path) }
    return .io("\(op) \(path) failed: \(msg)")
}
