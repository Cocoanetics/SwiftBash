import Foundation

// Permissions / ownership / link / xattr helpers for the in-memory
// file system. Split out from `InMemoryFileSystem.swift` to keep that
// type's body within the size budget.

extension InMemoryFileSystem {

    public func chmod(_ path: String, mode: UInt16) async throws {
        try lock.withLock {
            guard let node = resolveLocked(path) else {
                throw FileSystemError.notFound(path)
            }
            node.mode = mode & 0o7777
        }
    }

    public func chown(_ path: String, uid: UInt32?, gid: UInt32?) async throws {
        try lock.withLock {
            guard let node = resolveLocked(path) else {
                throw FileSystemError.notFound(path)
            }
            if let newUID = uid { node.uid = newUID }
            if let newGID = gid { node.gid = newGID }
        }
    }

    public func symlink(target: String, at linkPath: String) async throws {
        try lock.withLock {
            let components = Self.splitAbsolute(linkPath)
            guard let last = components.last else {
                throw FileSystemError.io("cannot symlink at root")
            }
            let parentComponents = Array(components.dropLast())
            guard let parent = resolveLocked(parentComponents),
                  case .directory(var children) = parent.kind
            else {
                throw FileSystemError.notFound(
                    "/" + parentComponents.joined(separator: "/"))
            }
            if children[last] != nil {
                throw FileSystemError.alreadyExists(linkPath)
            }
            children[last] = TreeNode(
                kind: .symlink(target: target, mtime: Date()),
                mode: 0o777)
            parent.kind = .directory(children)
        }
    }

    public func hardlink(target: String, at linkPath: String) async throws {
        try lock.withLock {
            guard let src = resolveLocked(target) else {
                throw FileSystemError.notFound(target)
            }
            let components = Self.splitAbsolute(linkPath)
            guard let last = components.last else {
                throw FileSystemError.io("cannot link at root")
            }
            let parentComponents = Array(components.dropLast())
            guard let parent = resolveLocked(parentComponents),
                  case .directory(var children) = parent.kind
            else {
                throw FileSystemError.notFound(
                    "/" + parentComponents.joined(separator: "/"))
            }
            if children[last] != nil {
                throw FileSystemError.alreadyExists(linkPath)
            }
            // True hard link semantics aren't expressible in our tree
            // (one node, two names) without reference-counting indirection,
            // but pointing the new entry at the same TreeNode object
            // gives the right behaviour for most observable operations.
            children[last] = src
            parent.kind = .directory(children)
        }
    }

    public func listXattrs(_ path: String) async throws -> [String] {
        try lock.withLock {
            guard let node = resolveLocked(path) else {
                throw FileSystemError.notFound(path)
            }
            return Array(node.xattrs.keys).sorted()
        }
    }

    public func getXattr(_ path: String, name: String) async throws -> Data {
        try lock.withLock {
            guard let node = resolveLocked(path) else {
                throw FileSystemError.notFound(path)
            }
            guard let value = node.xattrs[name] else {
                throw FileSystemError.io("no such xattr: \(name)")
            }
            return value
        }
    }

    public func setXattr(_ path: String, name: String, value: Data) async throws {
        try lock.withLock {
            guard let node = resolveLocked(path) else {
                throw FileSystemError.notFound(path)
            }
            node.xattrs[name] = value
        }
    }

    public func removeXattr(_ path: String, name: String) async throws {
        try lock.withLock {
            guard let node = resolveLocked(path) else {
                throw FileSystemError.notFound(path)
            }
            node.xattrs.removeValue(forKey: name)
        }
    }
}
