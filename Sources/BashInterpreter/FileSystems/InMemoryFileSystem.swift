import Foundation

/// A pure in-memory ``FileSystem`` useful for sandboxed scripts, unit
/// tests, iOS previews, or any scenario where you don't want to touch
/// a real disk.
///
/// Storage is a tree of nodes (files hold `Data`, directories hold a
/// name → child map) protected by an internal lock, so commands that
/// run concurrently in a pipeline see consistent state.
///
/// ```swift
/// let fs = InMemoryFileSystem()
/// try await fs.createDirectory("/tmp", intermediates: true)
/// try await fs.writeData(Data("hi\n".utf8), to: "/tmp/note", append: false)
///
/// let shell = Shell(fileSystem: fs)
/// shell.environment.workingDirectory = "/tmp"
/// ```
///
/// No symlinks, no permissions. Everything is UID 0 and world-readable.
public final class InMemoryFileSystem: FileSystem, @unchecked Sendable {

    // MARK: Internal tree

    final class TreeNode {
        enum Kind {
            case file(Data, mtime: Date)
            case directory([String: TreeNode])
        }
        var kind: Kind
        init(kind: Kind) { self.kind = kind }
    }

    private let lock = NSLock()
    private let root: TreeNode

    public init() {
        self.root = TreeNode(kind: .directory([:]))
    }

    /// Seed the file system from a dictionary of absolute paths to
    /// file contents. Intermediate directories are created as needed.
    public convenience init(files: [String: Data]) {
        self.init()
        for (path, data) in files {
            try? seed(path: path, data: data)
        }
    }

    private func seed(path: String, data: Data) throws {
        let components = Self.splitAbsolute(path)
        guard !components.isEmpty else { return }
        try lock.withLock {
            let parentComponents = Array(components.dropLast())
            let name = components.last!
            let parent = try ensureDirectory(at: parentComponents)
            guard case .directory(var children) = parent.kind else {
                throw FileSystemError.notADirectory(
                    "/" + parentComponents.joined(separator: "/"))
            }
            children[name] = TreeNode(kind: .file(data, mtime: Date()))
            parent.kind = .directory(children)
        }
    }

    // MARK: FileSystem conformance

    public func metadata(_ path: String) async throws -> FileMetadata? {
        lock.withLock {
            guard let node = resolveLocked(path) else { return nil }
            return Self.toMetadata(node)
        }
    }

    public func list(_ path: String) async throws -> [String] {
        try lock.withLock {
            guard let node = resolveLocked(path) else {
                throw FileSystemError.notFound(path)
            }
            guard case .directory(let children) = node.kind else {
                throw FileSystemError.notADirectory(path)
            }
            return Array(children.keys)
        }
    }

    public func canonicalize(_ path: String,
                             allowMissing: Bool) async throws -> String {
        let cleaned = Self.normalizePath(path)
        return try lock.withLock {
            if !allowMissing, resolveLocked(cleaned) == nil {
                throw FileSystemError.notFound(path)
            }
            return cleaned
        }
    }

    public func readData(_ path: String) async throws -> Data {
        try lock.withLock {
            guard let node = resolveLocked(path) else {
                throw FileSystemError.notFound(path)
            }
            switch node.kind {
            case .file(let data, _): return data
            case .directory:         throw FileSystemError.isADirectory(path)
            }
        }
    }

    public func writeData(_ data: Data, to path: String,
                          append: Bool) async throws
    {
        try lock.withLock { try writeLocked(data, to: path, append: append) }
    }

    public func openWrite(_ path: String,
                          append: Bool) async throws -> OutputSink
    {
        // For an in-memory store there's no real streaming benefit, but
        // we still want matching semantics: truncation happens eagerly,
        // and further bytes append as they arrive so readers iterating
        // `bytes` see live progress.
        try await writeData(Data(), to: path, append: append)
        let weakSelf = WeakFSBox(self)
        return OutputSink(
            bufferingPolicy: .bufferingOldest(0),
            onWrite: { data in
                guard let fs = weakSelf.value else { return }
                fs.lock.withLock {
                    try? fs.writeLocked(data, to: path, append: true)
                }
            })
    }

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
                case .file(let d, _):
                    existing.kind = .file(d, mtime: Date())
                case .directory:
                    break // touch on directory is a no-op
                }
            } else {
                children[last] = TreeNode(kind: .file(Data(), mtime: Date()))
                parent.kind = .directory(children)
            }
        }
    }

    public func createDirectory(_ path: String,
                                intermediates: Bool) async throws
    {
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
               !recursive
            {
                throw FileSystemError.isADirectory(path)
            }
            children.removeValue(forKey: last)
            parent.kind = .directory(children)
        }
    }

    public func move(from: String, to: String) async throws {
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

            let dstComponents = Self.splitAbsolute(to)
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
                    throw FileSystemError.alreadyExists(to)
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
                throw FileSystemError.alreadyExists(to)
            }
            srcChildren.removeValue(forKey: srcLast)
            srcParent.kind = .directory(srcChildren)
            dstChildren[dstLast] = node
            dstParent.kind = .directory(dstChildren)
        }
    }

    public func copy(from: String, to: String) async throws {
        try lock.withLock {
            guard let src = resolveLocked(from) else {
                throw FileSystemError.notFound(from)
            }
            let dstComponents = Self.splitAbsolute(to)
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
                throw FileSystemError.alreadyExists(to)
            }
            dstChildren[dstLast] = Self.deepCopy(src)
            dstParent.kind = .directory(dstChildren)
        }
    }

    // MARK: Internals (lock held)

    private func resolveLocked(_ path: String) -> TreeNode? {
        resolveLocked(Self.splitAbsolute(path))
    }

    private func resolveLocked(_ components: [String]) -> TreeNode? {
        var current: TreeNode = root
        for name in components {
            guard case .directory(let children) = current.kind,
                  let next = children[name]
            else { return nil }
            current = next
        }
        return current
    }

    private func writeLocked(_ data: Data, to path: String,
                             append: Bool) throws
    {
        let components = Self.splitAbsolute(path)
        guard let last = components.last else {
            throw FileSystemError.io("cannot write to root")
        }
        let parentComponents = Array(components.dropLast())
        guard let parent = resolveLocked(parentComponents),
              case .directory(var children) = parent.kind
        else {
            throw FileSystemError.notFound(
                "/" + parentComponents.joined(separator: "/"))
        }
        if case .directory = children[last]?.kind {
            throw FileSystemError.isADirectory(path)
        }
        var existing = Data()
        if append, case .file(let d, _) = children[last]?.kind {
            existing = d
        }
        existing.append(data)
        children[last] = TreeNode(kind: .file(existing, mtime: Date()))
        parent.kind = .directory(children)
    }

    private func ensureDirectory(at components: [String]) throws -> TreeNode {
        var current: TreeNode = root
        for name in components {
            guard case .directory(var children) = current.kind else {
                throw FileSystemError.notADirectory(name)
            }
            if let child = children[name] {
                if case .directory = child.kind {
                    current = child
                } else {
                    throw FileSystemError.notADirectory(name)
                }
            } else {
                let fresh = TreeNode(kind: .directory([:]))
                children[name] = fresh
                current.kind = .directory(children)
                current = fresh
            }
        }
        return current
    }

    // MARK: Static helpers

    private static func toMetadata(_ node: TreeNode) -> FileMetadata {
        switch node.kind {
        case .file(let data, let mtime):
            return FileMetadata(kind: .file,
                                size: Int64(data.count),
                                modifiedAt: mtime)
        case .directory:
            return FileMetadata(kind: .directory,
                                size: 0,
                                modifiedAt: Date(timeIntervalSince1970: 0))
        }
    }

    private static func deepCopy(_ node: TreeNode) -> TreeNode {
        switch node.kind {
        case .file(let data, let mtime):
            return TreeNode(kind: .file(data, mtime: mtime))
        case .directory(let children):
            var copied: [String: TreeNode] = [:]
            for (k, v) in children { copied[k] = deepCopy(v) }
            return TreeNode(kind: .directory(copied))
        }
    }

    static func splitAbsolute(_ path: String) -> [String] {
        let normalized = normalizePath(path)
        return normalized.split(separator: "/").map(String.init)
    }

    /// Collapse `.` and `..` segments. Leading `/` is preserved. Does
    /// not resolve symlinks (there aren't any).
    static func normalizePath(_ path: String) -> String {
        var stack: [String] = []
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        for seg in segments {
            switch seg {
            case ".": continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(seg))
            }
        }
        return "/" + stack.joined(separator: "/")
    }
}

/// Needed because OutputSink closures must be `@Sendable` — a strong
/// capture of the class would still be fine, but the weak form avoids
/// keeping a finished-but-never-closed sink alive past the FS.
final class WeakFSBox<T: AnyObject & Sendable>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
