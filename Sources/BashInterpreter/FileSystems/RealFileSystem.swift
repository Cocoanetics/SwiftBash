import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
// `<sys/xattr.h>` symbols aren't surfaced by Swift's stock Glibc
// module; the local CXattr systemLibrary target fills the gap.
import CXattr
#elseif canImport(WinSDK)
import WinSDK
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
        #if !os(Windows)
        // lstat first to detect symlinks and capture their target.
        var lst = stat()
        let lstatOK = path.withCString { lstat($0, &lst) } == 0

        var symlinkTarget: String? = nil
        if lstatOK, (lst.st_mode & S_IFMT) == S_IFLNK {
            var buf = [Int8](repeating: 0, count: 4096)
            let n = path.withCString { p in
                buf.withUnsafeMutableBufferPointer { bp in
                    // POSIX `readlink`. Linux's Glibc imports it
                    // with non-optional pointer parameters; force-
                    // unwrap `bp.baseAddress` (the buffer is
                    // non-empty by construction so it's never nil).
                    Self.libcReadlink(p, bp.baseAddress!, bp.count)
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
        #else
        return Self.windowsMetadata(path)
        #endif
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
            _ = fm.createFile(atPath: path, contents: nil)
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

#if !os(Windows)
private extension FileMetadata {
    static func fromStat(_ s: stat, symlinkTarget: String? = nil) -> FileMetadata {
        let kind: Kind
        let rawMode = s.st_mode
        if (rawMode & S_IFMT) == S_IFLNK       { kind = .symlink }
        else if (rawMode & S_IFMT) == S_IFDIR  { kind = .directory }
        else if (rawMode & S_IFMT) == S_IFREG  { kind = .file }
        else                                   { kind = .other }

        // Linux's `struct stat` spells the timespec fields without
        // the trailing `spec` (`st_mtim`, `st_atim`, `st_ctim`); Darwin
        // appends `spec`. The values are equivalent.
        #if canImport(Darwin)
        let mtime = Date(timeIntervalSince1970: TimeInterval(s.st_mtimespec.tv_sec))
        let atime = Date(timeIntervalSince1970: TimeInterval(s.st_atimespec.tv_sec))
        let ctime = Date(timeIntervalSince1970: TimeInterval(s.st_ctimespec.tv_sec))
        #else
        let mtime = Date(timeIntervalSince1970: TimeInterval(s.st_mtim.tv_sec))
        let atime = Date(timeIntervalSince1970: TimeInterval(s.st_atim.tv_sec))
        let ctime = Date(timeIntervalSince1970: TimeInterval(s.st_ctim.tv_sec))
        #endif
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
#endif

// MARK: - Permissions / links / xattrs

#if !os(Windows)
public extension RealFileSystem {

    func chmod(_ path: String, mode: UInt16) async throws {
        // POSIX `chmod`: unqualified resolves through whichever libc
        // module was imported up top (Darwin on Apple, Glibc on Linux).
        // We previously qualified as `Darwin.chmod` for clarity; that
        // doesn't compile on Linux.
        let r = path.withCString { Self.libcChmod($0, mode_t(mode)) }
        if r != 0 { throw fsError(op: "chmod", path: path) }
    }

    func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        let u = uid.map { uid_t($0) } ?? uid_t(bitPattern: -1)
        let g = gid.map { gid_t($0) } ?? gid_t(bitPattern: -1)
        let r = path.withCString { Self.libcChown($0, u, g) }
        if r != 0 { throw fsError(op: "chown", path: path) }
    }

    func symlink(target: String, at linkPath: String) async throws {
        let r = target.withCString { tp in
            linkPath.withCString { lp in
                Self.libcSymlink(tp, lp)
            }
        }
        if r != 0 { throw fsError(op: "symlink", path: linkPath) }
    }

    func hardlink(target: String, at linkPath: String) async throws {
        let r = target.withCString { tp in
            linkPath.withCString { lp in
                Self.libcLink(tp, lp)
            }
        }
        if r != 0 { throw fsError(op: "link", path: linkPath) }
    }

    /// Tiny per-platform aliases for the POSIX functions whose names
    /// collide with `FileSystem` protocol methods of the same name.
    /// Hoisting the call through a static reference lets Swift resolve
    /// the libc symbol without needing the `Darwin.` / `Glibc.` qualifier
    /// at every call site.
    #if canImport(Darwin)
    private static let libcChmod    = Darwin.chmod
    private static let libcChown    = Darwin.chown
    private static let libcSymlink  = Darwin.symlink
    private static let libcLink     = Darwin.link
    private static let libcReadlink = Darwin.readlink
    #else
    private static let libcChmod    = Glibc.chmod
    private static let libcChown    = Glibc.chown
    private static let libcSymlink  = Glibc.symlink
    private static let libcLink     = Glibc.link
    private static let libcReadlink = Glibc.readlink
    #endif

    // Extended attributes have meaningfully different signatures
    // between Darwin and Linux:
    //   - Darwin: `getxattr(path, name, value, size, position, options)`
    //   - Linux:  `getxattr(path, name, value, size)`            (no
    //             `position` / `options` args)
    // Each branch below is a faithful wrapper for the host's API.
    // The cross-platform behaviour is the same: read / write /
    // remove a named extended attribute on a regular file path,
    // returning the raw byte content (or empty data for empty
    // attrs). On platforms that lack any xattr support, fall
    // through to the protocol's default no-op-ish implementations.

    #if canImport(Darwin)

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
        return Self.parseXattrNameList(buf, length: written)
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

    #elseif canImport(Glibc)

    // Linux variants. Same semantics as the Darwin branch but the
    // C signatures take 4 args (no `position` / `options`). The
    // CXattr systemLibrary target wraps `<sys/xattr.h>` so the
    // symbols are in scope.

    func listXattrs(_ path: String) async throws -> [String] {
        let needed = path.withCString { listxattr($0, nil, 0) }
        if needed < 0 { throw fsError(op: "listxattr", path: path) }
        if needed == 0 { return [] }
        var buf = [Int8](repeating: 0, count: needed)
        let written = path.withCString { p in
            buf.withUnsafeMutableBufferPointer { bp in
                listxattr(p, bp.baseAddress, needed)
            }
        }
        if written < 0 { throw fsError(op: "listxattr", path: path) }
        return Self.parseXattrNameList(buf, length: written)
    }

    func getXattr(_ path: String, name: String) async throws -> Data {
        let needed = path.withCString { p in
            name.withCString { n in getxattr(p, n, nil, 0) }
        }
        if needed < 0 { throw fsError(op: "getxattr", path: path) }
        if needed == 0 { return Data() }
        var buf = [UInt8](repeating: 0, count: needed)
        let written = path.withCString { p in
            name.withCString { n in
                buf.withUnsafeMutableBufferPointer { bp in
                    getxattr(p, n, bp.baseAddress, needed)
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
                    setxattr(p, n, vb.baseAddress, value.count, 0)
                }
            }
        }
        if r < 0 { throw fsError(op: "setxattr", path: path) }
    }

    func removeXattr(_ path: String, name: String) async throws {
        let r = path.withCString { p in
            name.withCString { n in removexattr(p, n) }
        }
        // ENODATA (61 on Linux) means "no such attribute" — silent no-op.
        if r < 0 && errno != 61 {
            throw fsError(op: "removexattr", path: path)
        }
    }

    #endif

    /// Split the NUL-separated name list returned by `listxattr` into
    /// a `[String]`. Same parsing on both platforms.
    private static func parseXattrNameList(_ buf: [Int8], length: Int) -> [String] {
        var names: [String] = []
        var i = 0
        while i < length {
            let start = i
            while i < length, buf[i] != 0 { i += 1 }
            if i > start {
                let bytes = (start..<i).map { UInt8(bitPattern: buf[$0]) }
                names.append(String(decoding: bytes, as: UTF8.self))
            }
            i += 1
        }
        return names
    }
}

private func fsError(op: String, path: String) -> FileSystemError {
    let msg = String(cString: strerror(errno))
    if errno == ENOENT { return .notFound(path) }
    if errno == EACCES || errno == EPERM { return .permissionDenied(path) }
    return .io("\(op) \(path) failed: \(msg)")
}
#endif

#if os(Windows)

extension RealFileSystem {

    /// Win32-backed metadata. Reports symlink target by reading the
    /// reparse point, atime/ctime via `BY_HANDLE_FILE_INFORMATION`, and
    /// approximates POSIX mode bits from `FILE_ATTRIBUTE_READONLY`.
    static func windowsMetadata(_ path: String) -> FileMetadata? {
        // GetFileAttributesExW first — cheap, doesn't open the file.
        var basic = WIN32_FILE_ATTRIBUTE_DATA()
        let attrOK = path.withCString(encodedAs: UTF16.self) { wp -> Bool in
            GetFileAttributesExW(wp, GetFileExInfoStandard, &basic)
        }
        if !attrOK { return nil }

        let attrs = basic.dwFileAttributes
        let isDir = (attrs & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0
        let isSym = (attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) != 0
        let isReadOnly = (attrs & DWORD(FILE_ATTRIBUTE_READONLY)) != 0

        let kind: FileMetadata.Kind
        if isSym {
            kind = .symlink
        } else if isDir {
            kind = .directory
        } else {
            kind = .file
        }

        // Approximate POSIX mode: 0o755 for dirs, 0o644 for writable
        // files, 0o444 for read-only files. Add 0o111 for executable
        // would require parsing PE headers — skip.
        let mode: UInt16
        if isDir {
            mode = isReadOnly ? 0o555 : 0o755
        } else {
            mode = isReadOnly ? 0o444 : 0o644
        }

        let size = Int64(basic.nFileSizeHigh) << 32 | Int64(basic.nFileSizeLow)
        let mtime = filetimeToDate(basic.ftLastWriteTime)
        let ctime = filetimeToDate(basic.ftCreationTime)
        let atime = filetimeToDate(basic.ftLastAccessTime)

        // Open the file for link-count + symlink target. Skip for dirs
        // (CreateFileW needs FILE_FLAG_BACKUP_SEMANTICS for them and
        // the link count is meaningless).
        var linkCount = 1
        var symlinkTarget: String? = nil
        if !isDir {
            let openFlags: DWORD = isSym
                ? DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
                : 0
            let handle = path.withCString(encodedAs: UTF16.self) { wp in
                CreateFileW(wp,
                            0, // no read/write — query only
                            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                            nil,
                            DWORD(OPEN_EXISTING),
                            openFlags,
                            nil)
            }
            if handle != INVALID_HANDLE_VALUE {
                defer { CloseHandle(handle) }
                var info = BY_HANDLE_FILE_INFORMATION()
                if GetFileInformationByHandle(handle, &info) {
                    linkCount = Int(info.nNumberOfLinks)
                }
            }
        }
        if isSym {
            // Foundation knows how to read NTFS reparse points.
            symlinkTarget = try? FileManager.default
                .destinationOfSymbolicLink(atPath: path)
        }

        return FileMetadata(kind: kind,
                            size: size,
                            modifiedAt: mtime,
                            symlinkTarget: symlinkTarget,
                            mode: mode,
                            uid: 0,
                            gid: 0,
                            linkCount: linkCount,
                            accessedAt: atime,
                            createdAt: ctime)
    }

    /// Convert a Windows `FILETIME` (100-ns ticks since 1601-01-01) to
    /// a Foundation `Date`.
    private static func filetimeToDate(_ ft: FILETIME) -> Date {
        let raw = (UInt64(ft.dwHighDateTime) << 32) | UInt64(ft.dwLowDateTime)
        // Seconds between 1601-01-01 and 1970-01-01 (Unix epoch).
        let epochDeltaSeconds: Double = 11_644_473_600
        let unixSeconds = Double(raw) / 10_000_000.0 - epochDeltaSeconds
        return Date(timeIntervalSince1970: unixSeconds)
    }
}

public extension RealFileSystem {

    /// Approximate POSIX chmod via `_wchmod`. Windows only honours the
    /// "owner write" bit (mapped to the FILE_ATTRIBUTE_READONLY flag);
    /// any mode without `S_IWUSR` (0o200) marks the file read-only,
    /// otherwise it's writable. Other permission bits have no analog
    /// in NTFS without touching ACLs.
    func chmod(_ path: String, mode: UInt16) async throws {
        let writable = (mode & 0o200) != 0
        let winMode: Int32 = writable ? (0x0080 | 0x0100) /* _S_IWRITE | _S_IREAD */
                                      : 0x0100            /* _S_IREAD */
        let r = path.withCString(encodedAs: UTF16.self) { wp in
            _wchmod(wp, winMode)
        }
        if r != 0 { throw winFsError(op: "chmod", path: path) }
    }

    /// chown is meaningless on NTFS without ACL manipulation. Match the
    /// protocol's no-op default: only verify the path exists.
    func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        guard try await metadata(path) != nil else {
            throw FileSystemError.notFound(path)
        }
    }

    /// Symbolic link via `CreateSymbolicLinkW`. Pass
    /// `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE` so machines with
    /// Developer Mode enabled don't need to run elevated.
    func symlink(target: String, at linkPath: String) async throws {
        // Decide DIRECTORY vs file by probing the target.
        let isDir: Bool
        if let m = try? await metadata(target), m.kind == .directory {
            isDir = true
        } else {
            isDir = false
        }
        let dirFlag: DWORD = isDir ? 0x1 : 0x0
        let allowUnprivileged: DWORD = 0x2
        let flags = dirFlag | allowUnprivileged
        let ok = linkPath.withCString(encodedAs: UTF16.self) { lp -> Bool in
            target.withCString(encodedAs: UTF16.self) { tp -> Bool in
                // CreateSymbolicLinkW returns BOOLEAN (UCHAR), not BOOL —
                // compare against 0 explicitly.
                CreateSymbolicLinkW(lp, tp, flags) != 0
            }
        }
        if !ok { throw winFsError(op: "symlink", path: linkPath) }
    }

    /// Hard link via `CreateHardLinkW`.
    func hardlink(target: String, at linkPath: String) async throws {
        let ok = linkPath.withCString(encodedAs: UTF16.self) { lp -> Bool in
            target.withCString(encodedAs: UTF16.self) { tp -> Bool in
                CreateHardLinkW(lp, tp, nil)
            }
        }
        if !ok { throw winFsError(op: "link", path: linkPath) }
    }
}

private func winFsError(op: String, path: String) -> FileSystemError {
    let code = GetLastError()
    if code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND {
        return .notFound(path)
    }
    if code == ERROR_ACCESS_DENIED {
        return .permissionDenied(path)
    }
    return .io("\(op) \(path) failed (Win32 \(code))")
}

#endif
