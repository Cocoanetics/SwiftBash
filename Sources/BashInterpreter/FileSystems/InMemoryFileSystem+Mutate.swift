import Foundation

// Mutating operations (touch / mkdir / rm) for the in-memory file
// system. Split out from `InMemoryFileSystem.swift` to keep the type
// body within the size budget.

extension InMemoryFileSystem {

    public func touch(_ path: String) async throws {
        try lock.withLock {
            let components = Self.splitAbsolute(path)
            guard let last = components.last else {
                throw FileSystemError.io("cannot touch root")
            }
            let parentComponents = Array(components.dropLast())
            guard let parent = resolveLocked(parentComponents),
                  case .directory(var children) = parent.kind
            else {
                throw FileSystemError.notFound(
                    "/" + parentComponents.joined(separator: "/"))
            }
            if let existing = children[last] {
                switch existing.kind {
                case .file(let fileData, _):
                    existing.kind = .file(fileData, mtime: Date())
                case .directory:
                    break // touch on directory is a no-op
                case .symlink(let target, _):
                    existing.kind = .symlink(target: target, mtime: Date())
                }
            } else {
                children[last] = TreeNode(kind: .file(Data(), mtime: Date()))
                parent.kind = .directory(children)
            }
        }
    }

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws {
        try lock.withLock {
            let components = Self.splitAbsolute(path)
            guard !components.isEmpty else {
                throw FileSystemError.alreadyExists(path)
            }
            if intermediates {
                _ = try ensureDirectory(at: components)
                return
            }
            let parentComponents = Array(components.dropLast())
            let last = components.last!
            guard let parent = resolveLocked(parentComponents),
                  case .directory(var children) = parent.kind
            else {
                throw FileSystemError.notFound(
                    "/" + parentComponents.joined(separator: "/"))
            }
            if children[last] != nil {
                throw FileSystemError.alreadyExists(path)
            }
            children[last] = TreeNode(kind: .directory([:]))
            parent.kind = .directory(children)
        }
    }

    public func remove(_ path: String, recursive: Bool) async throws {
        try lock.withLock {
            let components = Self.splitAbsolute(path)
            guard let last = components.last else {
                throw FileSystemError.io("cannot remove root")
            }
            let parentComponents = Array(components.dropLast())
            guard let parent = resolveLocked(parentComponents),
                  case .directory(var children) = parent.kind
            else {
                throw FileSystemError.notFound(path)
            }
            guard let target = children[last] else {
                throw FileSystemError.notFound(path)
            }
            if case .directory(let inner) = target.kind,
               !inner.isEmpty,
               !recursive {
                throw FileSystemError.isADirectory(path)
            }
            children.removeValue(forKey: last)
            parent.kind = .directory(children)
        }
    }
}
