#if !os(Windows)

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// POSIX errno helpers used by the FS bridges. Split out of
// `JSRuntime.swift` to keep that file below the file_length limit.
extension JSRuntime {

    /// Extract POSIX errno from a Foundation/NSError. Cocoa
    /// file-system errors carry the original POSIXError nested under
    /// `NSUnderlyingErrorKey`; pull it out so we can map to a Node code.
    /// Returns 0 if no POSIX errno can be derived.
    static func posixErrno(from error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        // Cocoa file errors → best-guess mapping for the common cases.
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 4 /* NSFileNoSuchFileError */, 260 /* NSFileReadNoSuchFileError */:
                return ENOENT
            case 257 /* NSFileReadNoPermissionError */, 513 /* NSFileWriteNoPermissionError */:
                return EACCES
            case 516 /* NSFileWriteFileExistsError */:
                return EEXIST
            default: break
            }
        }
        return 0
    }

    // Map a POSIX errno to its Node-style symbolic code.
    // swiftlint:disable:next cyclomatic_complexity - flat errno→name dispatch
    static func posixCodeName(_ errno: Int32) -> String {
        switch errno {
        case ENOENT:    return "ENOENT"
        case EACCES:    return "EACCES"
        case EPERM:     return "EPERM"
        case EEXIST:    return "EEXIST"
        case ENOTDIR:   return "ENOTDIR"
        case EISDIR:    return "EISDIR"
        case ENOTEMPTY: return "ENOTEMPTY"
        case EBUSY:     return "EBUSY"
        case ENOSPC:    return "ENOSPC"
        case EROFS:     return "EROFS"
        case EMFILE:    return "EMFILE"
        case ENFILE:    return "ENFILE"
        case EINVAL:    return "EINVAL"
        case ENOMEM:    return "ENOMEM"
        case ELOOP:     return "ELOOP"
        case ENAMETOOLONG: return "ENAMETOOLONG"
        case EAGAIN:    return "EAGAIN"
        case EBADF:     return "EBADF"
        case EFAULT:    return "EFAULT"
        case EIO:       return "EIO"
        default:        return "UNKNOWN"
        }
    }

    // Node-style human-readable description for a POSIX errno.
    // Falls back to the OS string if we don't have a hard-coded one.
    // swiftlint:disable:next cyclomatic_complexity - flat errno→message dispatch
    static func posixDescription(_ errno: Int32, fallback: String) -> String {
        switch errno {
        case ENOENT:    return "no such file or directory"
        case EACCES:    return "permission denied"
        case EPERM:     return "operation not permitted"
        case EEXIST:    return "file already exists"
        case ENOTDIR:   return "not a directory"
        case EISDIR:    return "illegal operation on a directory"
        case ENOTEMPTY: return "directory not empty"
        case EBUSY:     return "resource busy or locked"
        case ENOSPC:    return "no space left on device"
        case EROFS:     return "read-only file system"
        case EMFILE, ENFILE: return "too many open files"
        case EINVAL:    return "invalid argument"
        case ENAMETOOLONG: return "name too long"
        case ELOOP:     return "too many symbolic links"
        case 0:         return fallback
        default:
            return String(cString: strerror(errno))
        }
    }
}

#endif  // !os(Windows)
