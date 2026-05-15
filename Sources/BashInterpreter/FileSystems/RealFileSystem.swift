import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
// `<sys/xattr.h>` symbols aren't surfaced by Swift's stock Android
// libc module; the local CXattr systemLibrary target fills the gap.
import CXattr
#elseif canImport(Bionic)
import Bionic
import CXattr
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

    var fileManager: FileManager { FileManager.default }

    // MARK: Inspection

    /// Follows symlinks — a symlink pointing at a directory reports
    /// `kind == .directory`. Returns `nil` if the path (or a broken
    /// symlink's target) doesn't exist.
    public func metadata(_ path: String) async throws -> FileMetadata? {
        #if !os(Windows)
        // lstat first to detect symlinks and capture their target.
        var lstatBuf = stat()
        let lstatOK = path.withCString { lstat($0, &lstatBuf) } == 0

        var symlinkTarget: String?
        if lstatOK, (lstatBuf.st_mode & S_IFMT) == S_IFLNK {
            var buf = [Int8](repeating: 0, count: 4096)
            let written = path.withCString { cPath in
                buf.withUnsafeMutableBufferPointer { bufPtr in
                    // POSIX `readlink`. Linux's Glibc imports it
                    // with non-optional pointer parameters; force-
                    // unwrap `bufPtr.baseAddress` (the buffer is
                    // non-empty by construction so it's never nil).
                    Self.libcReadlink(cPath, bufPtr.baseAddress!, bufPtr.count)
                }
            }
            if written > 0 {
                let bytes = (0..<Int(written)).map { UInt8(bitPattern: buf[$0]) }
                // readlink target may legitimately contain non-UTF-8 bytes.
                // swiftlint:disable:next optional_data_string_conversion
                symlinkTarget = String(decoding: bytes, as: UTF8.self)
            }
        }

        // Now follow symlinks for kind/size/mode etc. We use
        // `fstatat(AT_FDCWD, path, &statBuf, 0)` because the `stat`
        // symbol alone is ambiguous in Swift (the struct shadows the
        // function).
        var statBuf = stat()
        let statOK = path.withCString { fstatat(AT_FDCWD, $0, &statBuf, 0) } == 0
        if !statOK {
            // Broken symlink → return lstat info so callers can still see
            // the link target. Otherwise the path simply doesn't exist.
            if lstatOK {
                return FileMetadata.fromStat(lstatBuf, symlinkTarget: symlinkTarget)
            }
            return nil
        }
        return FileMetadata.fromStat(statBuf, symlinkTarget: symlinkTarget)
        #else
        return Self.windowsMetadata(path)
        #endif
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: path)
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            throw FileSystemError.notFound(path)
        } catch let error as NSError where error.code == NSFileReadUnknownError
                                    || error.code == 256 {
            throw FileSystemError.notADirectory(path)
        }
        // Pair each name with its metadata so callers get types in
        // one round-trip. Missing-metadata entries (race with delete,
        // unreadable subdirs, etc.) drop silently — matching how
        // `ls -1` skips an entry it can't stat.
        var entries: [FileEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            let child = (path as NSString).appendingPathComponent(name)
            if let meta = try? await metadata(child) {
                entries.append(FileEntry(name: name, metadata: meta))
            }
        }
        return entries
    }

    public func canonicalize(_ path: String,
                             allowMissing: Bool) async throws -> String {
        let url = URL(fileURLWithPath: path)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
        let resolved = url.path
        if !allowMissing, !fileManager.fileExists(atPath: resolved) {
            throw FileSystemError.notFound(path)
        }
        return resolved
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
