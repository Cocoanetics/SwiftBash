import Foundation

// Move / copy operations for the in-memory file system. Split out from
// `InMemoryFileSystem.swift` to keep the type body within the size budget.

extension InMemoryFileSystem {

    public func move(from: String, to destination: String) async throws {
        try lock.withLock {
            let srcComponents = Self.splitAbsolute(from)
            guard let srcLast = srcComponents.last else {
                throw FileSystemError.notFound(from)
            }
            let srcParentComponents = Array(srcComponents.dropLast())
            guard let srcParent = resolveLocked(srcParentComponents),
                  case .directory(let srcChildrenProbe) = srcParent.kind,
                  let node = srcChildrenProbe[srcLast]
            else {
                throw FileSystemError.notFound(from)
            }

            let dstComponents = Self.splitAbsolute(destination)
            guard let dstLast = dstComponents.last else {
                throw FileSystemError.io("cannot move to root")
            }
            let dstParentComponents = Array(dstComponents.dropLast())
            guard let dstParent = resolveLocked(dstParentComponents)
            else {
                throw FileSystemError.notFound(
                    "/" + dstParentComponents.joined(separator: "/"))
            }

            // Same-parent renames need one dictionary mutation, not two,
            // or we'd clobber the first with the second.
            if srcParent === dstParent {
                guard case .directory(var children) = srcParent.kind else {
                    throw FileSystemError.notADirectory(from)
                }
                if children[dstLast] != nil {
                    throw FileSystemError.alreadyExists(destination)
                }
                children.removeValue(forKey: srcLast)
                children[dstLast] = node
                srcParent.kind = .directory(children)
                return
            }

            guard case .directory(var srcChildren) = srcParent.kind,
                  case .directory(var dstChildren) = dstParent.kind
            else {
                throw FileSystemError.notADirectory(from)
            }
            if dstChildren[dstLast] != nil {
                throw FileSystemError.alreadyExists(destination)
            }
            srcChildren.removeValue(forKey: srcLast)
            srcParent.kind = .directory(srcChildren)
            dstChildren[dstLast] = node
            dstParent.kind = .directory(dstChildren)
        }
    }

    public func copy(from: String, to destination: String) async throws {
        try lock.withLock {
            guard let src = resolveLocked(from) else {
                throw FileSystemError.notFound(from)
            }
            let dstComponents = Self.splitAbsolute(destination)
            guard let dstLast = dstComponents.last else {
                throw FileSystemError.io("cannot copy to root")
            }
            let dstParentComponents = Array(dstComponents.dropLast())
            guard let dstParent = resolveLocked(dstParentComponents),
                  case .directory(var dstChildren) = dstParent.kind
            else {
                throw FileSystemError.notFound(
                    "/" + dstParentComponents.joined(separator: "/"))
            }
            if dstChildren[dstLast] != nil {
                throw FileSystemError.alreadyExists(destination)
            }
            dstChildren[dstLast] = Self.deepCopy(src)
            dstParent.kind = .directory(dstChildren)
        }
    }
}
