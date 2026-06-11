import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
import CXattr
#elseif canImport(Bionic)
import Bionic
import CXattr
#elseif canImport(Glibc)
import Glibc
import CXattr
#endif

#if !os(Windows)
extension FileMetadata {
    static func fromStat(_ statBuf: stat, symlinkTarget: String? = nil) -> FileMetadata {
        let kind: Kind
        let rawMode = statBuf.st_mode
        if (rawMode & S_IFMT) == S_IFLNK {
            kind = .symlink
        } else if (rawMode & S_IFMT) == S_IFDIR {
            kind = .directory
        } else if (rawMode & S_IFMT) == S_IFREG {
            kind = .file
        } else {
            kind = .other
        }

        // Linux's `struct stat` spells the timespec fields without
        // the trailing `spec` (`st_mtim`, `st_atim`, `st_ctim`); Darwin
        // appends `spec`. The values are equivalent.
        #if canImport(Darwin)
        let mtime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtimespec.tv_sec))
        let atime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_atimespec.tv_sec))
        let ctime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_ctimespec.tv_sec))
        #else
        let mtime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtim.tv_sec))
        let atime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_atim.tv_sec))
        let ctime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_ctim.tv_sec))
        #endif
        return FileMetadata(kind: kind,
                            size: Int64(statBuf.st_size),
                            modifiedAt: mtime,
                            symlinkTarget: symlinkTarget,
                            mode: UInt16(rawMode & 0o7777),
                            uid: UInt32(statBuf.st_uid),
                            gid: UInt32(statBuf.st_gid),
                            linkCount: Int(statBuf.st_nlink),
                            accessedAt: atime,
                            createdAt: ctime)
    }
}

// MARK: - Permissions / links / xattrs

public extension RealFileSystem {

    func chmod(_ path: String, mode: UInt16) async throws {
        // POSIX `chmod`: unqualified resolves through whichever libc
        // module was imported up top (Darwin on Apple, Glibc on Linux).
        // We previously qualified as `Darwin.chmod` for clarity; that
        // doesn't compile on Linux.
        let result = path.withCString { Self.libcChmod($0, mode_t(mode)) }
        if result != 0 { throw fsError(op: "chmod", path: path) }
    }

    func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        let userID = uid.map { uid_t($0) } ?? uid_t(bitPattern: -1)
        let groupID = gid.map { gid_t($0) } ?? gid_t(bitPattern: -1)
        let result = path.withCString { Self.libcChown($0, userID, groupID) }
        if result != 0 { throw fsError(op: "chown", path: path) }
    }

    func symlink(target: String, at linkPath: String) async throws {
        let result = target.withCString { targetPtr in
            linkPath.withCString { linkPtr in
                Self.libcSymlink(targetPtr, linkPtr)
            }
        }
        if result != 0 { throw fsError(op: "symlink", path: linkPath) }
    }

    func hardlink(target: String, at linkPath: String) async throws {
        let result = target.withCString { targetPtr in
            linkPath.withCString { linkPtr in
                Self.libcLink(targetPtr, linkPtr)
            }
        }
        if result != 0 { throw fsError(op: "link", path: linkPath) }
    }

    /// Tiny per-platform aliases for the POSIX functions whose names
    /// collide with `FileSystem` protocol methods of the same name.
    /// Hoisting the call through a static reference lets Swift resolve
    /// the libc symbol without needing the `Darwin.` / `Glibc.` qualifier
    /// at every call site.
    #if canImport(Darwin)
    static let libcChmod    = Darwin.chmod
    static let libcChown    = Darwin.chown
    static let libcSymlink  = Darwin.symlink
    static let libcLink     = Darwin.link
    static let libcReadlink = Darwin.readlink
    #elseif canImport(Android)
    static let libcChmod    = Android.chmod
    static let libcChown    = Android.chown
    static let libcSymlink  = Android.symlink
    static let libcLink     = Android.link
    static let libcReadlink = Android.readlink
    #elseif canImport(Bionic)
    static let libcChmod    = Bionic.chmod
    static let libcChown    = Bionic.chown
    static let libcSymlink  = Bionic.symlink
    static let libcLink     = Bionic.link
    static let libcReadlink = Bionic.readlink
    #else
    static let libcChmod    = Glibc.chmod
    static let libcChown    = Glibc.chown
    static let libcSymlink  = Glibc.symlink
    static let libcLink     = Glibc.link
    static let libcReadlink = Glibc.readlink
    #endif

    /// Split the NUL-separated name list returned by `listxattr` into
    /// a `[String]`. Same parsing on both platforms.
    static func parseXattrNameList(_ buf: [Int8], length: Int) -> [String] {
        var names: [String] = []
        var index = 0
        while index < length {
            let start = index
            while index < length, buf[index] != 0 { index += 1 }
            if index > start {
                let bytes = (start..<index).map { UInt8(bitPattern: buf[$0]) }
                // xattr name bytes are platform-defined; tolerate non-UTF-8.
                // swiftlint:disable:next optional_data_string_conversion
                names.append(String(decoding: bytes, as: UTF8.self))
            }
            index += 1
        }
        return names
    }
}

func fsError(op operation: String, path: String) -> FileSystemError {
    // Capture `errno` once, up front. It's a thread-local global that any
    // intervening libc call — `strerror` included — is permitted to
    // overwrite, so re-reading it after the message lookup (as this used
    // to) risks classifying the error off a clobbered value.
    let code = errno
    switch code {
    case ENOENT:
        return .notFound(path)
    case EACCES, EPERM:
        return .permissionDenied(path)
    default:
        return .io("\(operation) \(path) failed: \(String(cString: strerror(code)))")
    }
}
#endif
