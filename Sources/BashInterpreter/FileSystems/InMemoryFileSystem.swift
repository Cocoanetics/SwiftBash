import Foundation

// Internal in-memory tree node for InMemoryFileSystem. Lifted out of
// the host type so the `Kind` enum doesn't trip nesting limits.
final class InMemoryFileSystemNode {
    enum Kind {
        case file(Data, mtime: Date)
        case directory([String: InMemoryFileSystemNode])
        case symlink(target: String, mtime: Date)
    }
    var kind: Kind
    var mode: UInt16
    var uid: UInt32
    var gid: UInt32
    var xattrs: [String: Data]
    init(kind: Kind, mode: UInt16? = nil,
         uid: UInt32 = 1000, gid: UInt32 = 1000) {
        self.kind = kind
        if let modeBits = mode {
            self.mode = modeBits
        } else if case .directory = kind {
            self.mode = 0o755
        } else {
            self.mode = 0o644
        }
        // Default owner matches `HostInfo.synthetic` (1000/1000).
        // We deliberately do NOT call `getuid()` / `getgid()` —
        // doing so would let `stat foo` reveal the real host uid
        // even when the rest of the shell reports synthetic
        // identity. Embedders that want host owners assign
        // `node.uid = …` after construction.
        self.uid = uid
        self.gid = gid
        self.xattrs = [:]
    }
}

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
/// Shell.bashCurrent.environment.workingDirectory = "/tmp"
/// ```
///
/// No symlinks, no permissions. Everything is UID 0 and world-readable.
public final class InMemoryFileSystem: FileSystem, @unchecked Sendable {

    // MARK: Internal tree

    typealias TreeNode = InMemoryFileSystemNode

    let lock = NSLock()
    let root: TreeNode

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

    public func list(_ path: String) async throws -> [FileEntry] {
        try lock.withLock {
            guard let node = resolveLocked(path) else {
                throw FileSystemError.notFound(path)
            }
            guard case .directory(let children) = node.kind else {
                throw FileSystemError.notADirectory(path)
            }
            return children.map { name, child in
                FileEntry(name: name, metadata: Self.toMetadata(child))
            }
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
            case .symlink(let target, _):
                // Read through the symlink to its target.
                guard let resolved = resolveLocked(target) else {
                    throw FileSystemError.notFound(path)
                }
                if case .file(let resolvedData, _) = resolved.kind { return resolvedData }
                throw FileSystemError.isADirectory(path)
            }
        }
    }

    public func writeData(_ data: Data, to path: String,
                          append: Bool) async throws {
        try lock.withLock { try writeLocked(data, to: path, append: append) }
    }

    public func openWrite(_ path: String,
                          append: Bool) async throws -> OutputSink {
        // For an in-memory store there's no real streaming benefit, but
        // we still want matching semantics: truncation happens eagerly,
        // and further bytes append as they arrive so readers iterating
        // `bytes` see live progress.
        try await writeData(Data(), to: path, append: append)
        let weakSelf = WeakFSBox(self)
        return OutputSink(
            bufferingPolicy: .bufferingOldest(0),
            onWrite: { data in
                guard let strongSelf = weakSelf.value else { return }
                strongSelf.lock.withLock {
                    try? strongSelf.writeLocked(data, to: path, append: true)
                }
            })
    }

    // MARK: Internals (lock held)

    func resolveLocked(_ path: String) -> TreeNode? {
        resolveLocked(Self.splitAbsolute(path))
    }

    func resolveLocked(_ components: [String]) -> TreeNode? {
        var current: TreeNode = root
        for name in components {
            guard case .directory(let children) = current.kind,
                  let next = children[name]
            else { return nil }
            current = next
        }
        return current
    }

    func writeLocked(_ data: Data, to path: String,
                     append: Bool) throws {
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
        if append, case .file(let existingData, _) = children[last]?.kind {
            existing = existingData
        }
        existing.append(data)
        children[last] = TreeNode(kind: .file(existing, mtime: Date()))
        parent.kind = .directory(children)
    }

    func ensureDirectory(at components: [String]) throws -> TreeNode {
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
                                modifiedAt: mtime,
                                mode: node.mode,
                                uid: node.uid,
                                gid: node.gid)
        case .directory:
            return FileMetadata(kind: .directory,
                                size: 0,
                                modifiedAt: Date(timeIntervalSince1970: 0),
                                mode: node.mode,
                                uid: node.uid,
                                gid: node.gid)
        case .symlink(let target, let mtime):
            return FileMetadata(kind: .symlink,
                                size: Int64(target.utf8.count),
                                modifiedAt: mtime,
                                symlinkTarget: target,
                                mode: node.mode,
                                uid: node.uid,
                                gid: node.gid)
        }
    }

    static func deepCopy(_ node: TreeNode) -> TreeNode {
        let new: TreeNode
        switch node.kind {
        case .file(let data, let mtime):
            new = TreeNode(kind: .file(data, mtime: mtime), mode: node.mode)
        case .directory(let children):
            var copied: [String: TreeNode] = [:]
            for (key, child) in children { copied[key] = deepCopy(child) }
            new = TreeNode(kind: .directory(copied), mode: node.mode)
        case .symlink(let target, let mtime):
            new = TreeNode(kind: .symlink(target: target, mtime: mtime),
                           mode: node.mode)
        }
        new.uid = node.uid
        new.gid = node.gid
        new.xattrs = node.xattrs
        return new
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
