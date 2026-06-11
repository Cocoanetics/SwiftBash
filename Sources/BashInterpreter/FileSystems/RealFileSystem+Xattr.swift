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

public extension RealFileSystem {

    func listXattrs(_ path: String) async throws -> [String] {
        let needed = path.withCString { listxattr($0, nil, 0, 0) }
        if needed < 0 { throw fsError(op: "listxattr", path: path) }
        if needed == 0 { return [] }
        var buf = [Int8](repeating: 0, count: needed)
        let written = path.withCString { pathPtr in
            buf.withUnsafeMutableBufferPointer { bufPtr in
                listxattr(pathPtr, bufPtr.baseAddress, needed, 0)
            }
        }
        if written < 0 { throw fsError(op: "listxattr", path: path) }
        return Self.parseXattrNameList(buf, length: written)
    }

    func getXattr(_ path: String, name: String) async throws -> Data {
        let needed = path.withCString { pathPtr in
            name.withCString { namePtr in
                getxattr(pathPtr, namePtr, nil, 0, 0, 0)
            }
        }
        if needed < 0 { throw fsError(op: "getxattr", path: path) }
        if needed == 0 { return Data() }
        var buf = [UInt8](repeating: 0, count: needed)
        let written = path.withCString { pathPtr in
            name.withCString { namePtr in
                buf.withUnsafeMutableBufferPointer { bufPtr in
                    getxattr(pathPtr, namePtr, bufPtr.baseAddress, needed, 0, 0)
                }
            }
        }
        if written < 0 { throw fsError(op: "getxattr", path: path) }
        return Data(buf.prefix(written))
    }

    func setXattr(_ path: String, name: String, value: Data) async throws {
        let result = path.withCString { pathPtr in
            name.withCString { namePtr in
                value.withUnsafeBytes { valuePtr in
                    setxattr(pathPtr, namePtr, valuePtr.baseAddress, value.count, 0, 0)
                }
            }
        }
        if result < 0 { throw fsError(op: "setxattr", path: path) }
    }

    func removeXattr(_ path: String, name: String) async throws {
        let result = path.withCString { pathPtr in
            name.withCString { namePtr in removexattr(pathPtr, namePtr, 0) }
        }
        // ENOATTR ("attribute not found") is fine — silent no-op.
        if result < 0 && errno != ENOATTR {
            throw fsError(op: "removexattr", path: path)
        }
    }
}

#elseif canImport(Glibc) || canImport(Bionic) || canImport(Android)

// Linux / Android variants. Same semantics as the Darwin branch but
// the C signatures take 4 args (no `position` / `options`). The
// CXattr systemLibrary target wraps `<sys/xattr.h>` so the
// symbols are in scope.

public extension RealFileSystem {

    func listXattrs(_ path: String) async throws -> [String] {
        let needed = path.withCString { listxattr($0, nil, 0) }
        if needed < 0 { throw fsError(op: "listxattr", path: path) }
        if needed == 0 { return [] }
        var buf = [Int8](repeating: 0, count: needed)
        let written = path.withCString { pathPtr in
            buf.withUnsafeMutableBufferPointer { bufPtr in
                listxattr(pathPtr, bufPtr.baseAddress, needed)
            }
        }
        if written < 0 { throw fsError(op: "listxattr", path: path) }
        return Self.parseXattrNameList(buf, length: written)
    }

    func getXattr(_ path: String, name: String) async throws -> Data {
        let needed = path.withCString { pathPtr in
            name.withCString { namePtr in getxattr(pathPtr, namePtr, nil, 0) }
        }
        if needed < 0 { throw fsError(op: "getxattr", path: path) }
        if needed == 0 { return Data() }
        var buf = [UInt8](repeating: 0, count: needed)
        let written = path.withCString { pathPtr in
            name.withCString { namePtr in
                buf.withUnsafeMutableBufferPointer { bufPtr in
                    getxattr(pathPtr, namePtr, bufPtr.baseAddress, needed)
                }
            }
        }
        if written < 0 { throw fsError(op: "getxattr", path: path) }
        return Data(buf.prefix(written))
    }

    func setXattr(_ path: String, name: String, value: Data) async throws {
        let result = path.withCString { pathPtr in
            name.withCString { namePtr in
                value.withUnsafeBytes { valuePtr in
                    setxattr(pathPtr, namePtr, valuePtr.baseAddress, value.count, 0)
                }
            }
        }
        if result < 0 { throw fsError(op: "setxattr", path: path) }
    }

    func removeXattr(_ path: String, name: String) async throws {
        let result = path.withCString { pathPtr in
            name.withCString { namePtr in removexattr(pathPtr, namePtr) }
        }
        // ENODATA ("attribute not found") means no such attribute — silent no-op.
        if result < 0 && errno != ENODATA {
            throw fsError(op: "removexattr", path: path)
        }
    }
}

#endif
