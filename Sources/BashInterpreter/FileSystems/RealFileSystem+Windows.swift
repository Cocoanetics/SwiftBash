import Foundation

#if os(Windows)
import WinSDK

extension RealFileSystem {

    // Win32-backed metadata. Reports symlink target by reading the
    // reparse point, atime/ctime via `BY_HANDLE_FILE_INFORMATION`, and
    // approximates POSIX mode bits from `FILE_ATTRIBUTE_READONLY`.
    //
    // Open-and-query plus attribute branch logic is intrinsically wide;
    // splitting per-attribute would lose the shared open-handle block.
    // swiftlint:disable:next function_body_length
    static func windowsMetadata(_ path: String) -> FileMetadata? {
        // GetFileAttributesExW first — cheap, doesn't open the file.
        var basic = WIN32_FILE_ATTRIBUTE_DATA()
        let attrOK = path.withCString(encodedAs: UTF16.self) { widePath -> Bool in
            GetFileAttributesExW(widePath, GetFileExInfoStandard, &basic)
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
        var symlinkTarget: String?
        if !isDir {
            let openFlags: DWORD = isSym
                ? DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
                : 0
            let handle = path.withCString(encodedAs: UTF16.self) { widePath in
                CreateFileW(widePath,
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
    static func filetimeToDate(_ fileTime: FILETIME) -> Date {
        let raw = (UInt64(fileTime.dwHighDateTime) << 32) | UInt64(fileTime.dwLowDateTime)
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
        let result = path.withCString(encodedAs: UTF16.self) { widePath in
            _wchmod(widePath, winMode)
        }
        if result != 0 { throw winFsError(op: "chmod", path: path) }
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
        if let meta = try? await metadata(target), meta.kind == .directory {
            isDir = true
        } else {
            isDir = false
        }
        let dirFlag: DWORD = isDir ? 0x1 : 0x0
        let allowUnprivileged: DWORD = 0x2
        let flags = dirFlag | allowUnprivileged
        let success = linkPath.withCString(encodedAs: UTF16.self) { linkPtr -> Bool in
            target.withCString(encodedAs: UTF16.self) { targetPtr -> Bool in
                // CreateSymbolicLinkW returns BOOLEAN (UCHAR), not BOOL —
                // compare against 0 explicitly.
                CreateSymbolicLinkW(linkPtr, targetPtr, flags) != 0
            }
        }
        if !success { throw winFsError(op: "symlink", path: linkPath) }
    }

    /// Hard link via `CreateHardLinkW`.
    func hardlink(target: String, at linkPath: String) async throws {
        let success = linkPath.withCString(encodedAs: UTF16.self) { linkPtr -> Bool in
            target.withCString(encodedAs: UTF16.self) { targetPtr -> Bool in
                CreateHardLinkW(linkPtr, targetPtr, nil)
            }
        }
        if !success { throw winFsError(op: "link", path: linkPath) }
    }
}

func winFsError(op operation: String, path: String) -> FileSystemError {
    let code = GetLastError()
    if code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND {
        return .notFound(path)
    }
    if code == ERROR_ACCESS_DENIED {
        return .permissionDenied(path)
    }
    return .io("\(operation) \(path) failed (Win32 \(code))")
}

#endif
